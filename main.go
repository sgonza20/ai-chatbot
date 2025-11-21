package main

import (
	"context"
	"encoding/json"
	"log"
	"net/http"
	"os"
	"sync"
	"time"

	"github.com/aws/aws-sdk-go-v2/config"
	bedrock "github.com/aws/aws-sdk-go-v2/service/bedrockruntime"
)

// --- Structs for Chat State and API Communication ---

type ChatRequest struct {
	Message string `json:"message"` // Matches the key sent by the frontend
}

// ChatResponse is what the frontend expects back
type ChatResponse struct {
	Response string `json:"response"`
}

type Message struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

var (
	store = struct {
		sync.RWMutex
		m []Message
	}{}
	modelID = os.Getenv("MODEL_ID")
	region  = os.Getenv("AWS_REGION")
)

// --- CORS Middleware ---

// corsMiddleware wraps an HTTP handler and adds necessary CORS headers.
// IMPORTANT: In production, replace "*" with the exact domain of your CloudFront frontend URL
// (e.g., "https://d1234.cloudfront.net")
func corsMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Allow requests from all origins during development/testing.
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "POST, GET, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Accept, Content-Type, Content-Length, Accept-Encoding, X-CSRF-Token, Authorization")

		// Handle preflight OPTIONS request required by browsers before a POST
		if r.Method == "OPTIONS" {
			w.WriteHeader(http.StatusOK)
			return
		}

		// Pass the request to the next handler
		next.ServeHTTP(w, r)
	})
}

// --- Main Application Logic ---

func main() {
	if modelID == "" {
		// Example model ID for Claude Sonnet 3.5
		modelID = "arn:aws:bedrock:us-east-1:949940714686:inference-profile/global.anthropic.claude-sonnet-4-20250514-v1:0"
	}
	if region == "" {
		region = "us-east-1"
	}

	ctx := context.Background()
	cfg, err := config.LoadDefaultConfig(ctx, config.WithRegion(region))
	if err != nil {
		log.Fatalf("unable to load aws config: %v", err)
	}

	br := bedrock.NewFromConfig(cfg)

	// Create a new ServeMux to define routes
	chatMux := http.NewServeMux()

	// 1. Health check handler
	chatMux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("ok"))
	})

	// 2. Chat handler (API Endpoint)
	chatMux.HandleFunc("/chat", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "only POST", http.StatusMethodNotAllowed)
			return
		}

		var cr ChatRequest
		if err := json.NewDecoder(r.Body).Decode(&cr); err != nil {
			http.Error(w, "bad request: "+err.Error(), http.StatusBadRequest)
			return
		}

		store.Lock()
		store.m = append(store.m, Message{Role: "user", Content: cr.Message})
		store.Unlock()

		// Build Anthropic messages format
		type contentBlock struct {
			Type string `json:"type"`
			Text string `json:"text"`
		}
		type inMessage struct {
			Role    string         `json:"role"`
			Content []contentBlock `json:"content"`
		}
		var messagesPayload []inMessage
		store.RLock()
		for _, m := range store.m {
			messagesPayload = append(messagesPayload, inMessage{
				Role:    m.Role,
				Content: []contentBlock{{Type: "text", Text: m.Content}},
			})
		}
		store.RUnlock()

		reqBody := map[string]interface{}{
			"messages":          messagesPayload,
			"max_tokens":        1024,
			"temperature":       0.3,
			"anthropic_version": "bedrock-2023-05-31",
		}
		b, _ := json.Marshal(reqBody)

		input := &bedrock.InvokeModelInput{
			Body:        b,
			ModelId:     &modelID,
			ContentType: awsString("application/json"),
		}

		out, err := br.InvokeModel(r.Context(), input)
		if err != nil {
			log.Printf("InvokeModel error: %v", err)
			http.Error(w, "model error: "+err.Error(), http.StatusInternalServerError)
			return
		}

		var parsed map[string]interface{}
		if err := json.Unmarshal(out.Body, &parsed); err != nil {
			log.Printf("failed to parse model response: %v", err)
			http.Error(w, "failed to parse model response", http.StatusInternalServerError)
			return
		}

		log.Printf("Raw model response: %s", string(out.Body))
		log.Println("Testing SAST")

		assistantText := extractAssistantText(parsed)
		if assistantText == "" {
			assistantText = "(no text returned)"
		}

		store.Lock()
		store.m = append(store.m, Message{Role: "assistant", Content: assistantText})
		store.Unlock()

		// --- RESPONSE FORMAT FIX: Respond with JSON as expected by the React frontend ---
		resp := ChatResponse{Response: assistantText}
		respB, err := json.Marshal(resp)
		if err != nil {
			http.Error(w, "internal response error", http.StatusInternalServerError)
			return
		}

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(respB)
	})

	// Apply the CORS middleware to the entire router
	handlerWithCORS := corsMiddleware(chatMux)

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}
	srv := &http.Server{
		Addr:         ":" + port,
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 120 * time.Second,
		Handler:      handlerWithCORS, // Use the wrapped handler
	}

	log.Printf("listening on %s (model=%s region=%s)", srv.Addr, modelID, region)
	log.Fatal(srv.ListenAndServe())
}

func awsString(s string) *string { return &s }

// ✅ Updated to handle Claude 3.x, 3.5, and 4.x formats
func extractAssistantText(parsed map[string]interface{}) string {
	// Claude 3.5+ often returns "output_text"
	if text, ok := parsed["output_text"].(string); ok && text != "" {
		return text
	}

	// Claude 3.x / Anthropic standard message format
	if choices, ok := parsed["choices"].([]interface{}); ok && len(choices) > 0 {
		if c0, ok := choices[0].(map[string]interface{}); ok {
			if msg, ok := c0["message"].(map[string]interface{}); ok {
				if content, ok := msg["content"].([]interface{}); ok && len(content) > 0 {
					if cb, ok := content[0].(map[string]interface{}); ok {
						if t, ok := cb["text"].(string); ok {
							return t
						}
					}
				}
			}
			if t, ok := c0["text"].(string); ok {
				return t
			}
		}
	}

	// Claude 4.x or unknown fallback: "content" array directly at top-level
	if content, ok := parsed["content"].([]interface{}); ok && len(content) > 0 {
		if cb, ok := content[0].(map[string]interface{}); ok {
			if t, ok := cb["text"].(string); ok {
				return t
			}
		}
	}

	return ""
}
