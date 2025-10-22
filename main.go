// main.go example
package main

import (
	"log"
	"net/http"
)

func main() {
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("Hello from the Go Chatbot!"))
	})

	log.Fatal(http.ListenAndServe(":8080", nil)) // Listen on port 8080
}
