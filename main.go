// main.go
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

type ChatRequest struct {
	Message string `json:"message"`
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

func main() {
	if modelID == "" {
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

	http.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("ok"))
	})

	http.HandleFunc("/chat", func(w http.ResponseWriter, r *http.Request) {
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

		// 🔍 Log the full model response for debugging
		log.Printf("Raw model response: %s", string(out.Body))

		assistantText := extractAssistantText(parsed)
		if assistantText == "" {
			assistantText = "(no text returned)"
		}

		store.Lock()
		store.m = append(store.m, Message{Role: "assistant", Content: assistantText})
		store.Unlock()

		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = w.Write([]byte(assistantText))
	})

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}
	srv := &http.Server{
		Addr:         ":" + port,
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 120 * time.Second,
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
