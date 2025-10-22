// main.go
package main

import (
	"context"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"os"
	"sync"
	"time"

	"github.com/aws/aws-sdk-go-v2/config"
	bedrock "github.com/aws/aws-sdk-go-v2/service/bedrockruntime"
)

// Request/Response shapes for our HTTP API
type ChatRequest struct {
	SessionID string `json:"session_id"`
	Message   string `json:"message"`
}

type ChatResponse struct {
	SessionID string `json:"session_id"`
	Reply     string `json:"reply"`
}

var (
	modelID = os.Getenv("MODEL_ID") // e.g. "anthropic.claude-3-opus-20240229-v1:0"
	region  = os.Getenv("AWS_REGION")
)

// very small in-memory conversation store (sessionID -> []messages)
// For production: replace with DynamoDB/Redis/whatever.
type Message struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

var store = struct {
	sync.RWMutex
	m map[string][]Message
}{m: map[string][]Message{}}

func main() {
	if modelID == "" {
		log.Fatal("MODEL_ID environment variable is required")
	}
	if region == "" {
		region = "us-east-1"
	}

	ctx := context.Background()
	cfg, err := config.LoadDefaultConfig(ctx, config.WithRegion(region))
	if err != nil {
		log.Fatalf("unable to load aws config: %v", err)
	}

	// Bedrock Runtime client
	br := bedrock.NewFromConfig(cfg)

	http.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		io.WriteString(w, "ok")
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
		// append user message to session history
		store.Lock()
		history := store.m[cr.SessionID]
		history = append(history, Message{Role: "user", Content: cr.Message})
		store.m[cr.SessionID] = history
		store.Unlock()

		// Build the Anthropic "messages" payload expected by Claude Messages API
		// Each message is {"role": "user" | "assistant" | "system", "content":[{"type":"text","text":"..."}]}
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
		for _, m := range store.m[cr.SessionID] {
			messagesPayload = append(messagesPayload, inMessage{
				Role:    m.Role,
				Content: []contentBlock{{Type: "text", Text: m.Content}},
			})
		}
		store.RUnlock()

		// Build request body (JSON) that Bedrock's InvokeModel expects for Anthropic Messages API
		reqBody := map[string]interface{}{
			"messages": messagesPayload,
			// You can tune other parameters (max_tokens, temperature, etc.) per model docs
			"max_tokens":        1024,
			"anthropic_version": "bedrock-2023-05-31",
			"temperature":       0.3,
		}
		b, _ := json.Marshal(reqBody)

		// Call Bedrock Runtime InvokeModel
		input := &bedrock.InvokeModelInput{
			Body:        b,
			ModelId:     &modelID,
			ContentType: awsString("application/json"),
		}

		// non-streaming call (simpler). For streaming use InvokeModelWithResponseStream.
		out, err := br.InvokeModel(r.Context(), input)
		if err != nil {
			log.Printf("InvokeModel error: %v", err)
			http.Error(w, "model error: "+err.Error(), http.StatusInternalServerError)
			return
		}

		// Output from bedrock: Body is an io.ReadCloser-like []byte. We'll parse it expecting JSON.
		respBytes := out.Body
		// The response body is model-specific; for Claude Messages it typically returns a JSON message structure.
		var parsed map[string]interface{}
		if err := json.Unmarshal(respBytes, &parsed); err != nil {
			// fallback: return raw text
			reply := string(respBytes)
			// append assistant reply to history
			store.Lock()
			store.m[cr.SessionID] = append(store.m[cr.SessionID], Message{Role: "assistant", Content: reply})
			store.Unlock()

			writeJSON(w, ChatResponse{SessionID: cr.SessionID, Reply: reply})
			return
		}

		// Try to extract the assistant text from common keys:
		assistantText := extractAssistantText(parsed)
		if assistantText == "" {
			// fallback to marshalled full response
			bs, _ := json.Marshal(parsed)
			assistantText = string(bs)
		}

		// update history with model reply
		store.Lock()
		store.m[cr.SessionID] = append(store.m[cr.SessionID], Message{Role: "assistant", Content: assistantText})
		store.Unlock()

		writeJSON(w, ChatResponse{SessionID: cr.SessionID, Reply: assistantText})
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

// helper functions

func writeJSON(w http.ResponseWriter, v interface{}) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(v)
}

func awsString(s string) *string {
	return &s
}

// extractAssistantText tries common response shapes for Claude messages output
func extractAssistantText(parsed map[string]interface{}) string {
	// Common shape: {"choices":[{"message":{"content":[{"type":"text","text":"..."}]}}]}
	if choices, ok := parsed["choices"].([]interface{}); ok && len(choices) > 0 {
		if c0, ok := choices[0].(map[string]interface{}); ok {
			// try .message.content[0].text
			if msg, ok := c0["message"].(map[string]interface{}); ok {
				if content, ok := msg["content"].([]interface{}); ok && len(content) > 0 {
					if cb, ok := content[0].(map[string]interface{}); ok {
						if t, ok := cb["text"].(string); ok {
							return t
						}
					}
				}
			}
			// try .text
			if t, ok := c0["text"].(string); ok {
				return t
			}
		}
	}
	// Try top-level "message" with content
	if msg, ok := parsed["message"].(map[string]interface{}); ok {
		if content, ok := msg["content"].([]interface{}); ok && len(content) > 0 {
			if cb, ok := content[0].(map[string]interface{}); ok {
				if t, ok := cb["text"].(string); ok {
					return t
				}
			}
		}
	}
	// fail: return empty
	return ""
}
