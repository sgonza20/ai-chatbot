# Stage 1: Build the Go application
FROM golang:1.25-alpine AS builder
WORKDIR /app
COPY . .
RUN go mod download


# CGO_ENABLED=0 is important for creating statically linked binaries
RUN CGO_ENABLED=0 GOOS=linux go build -a -installsuffix nocgo -o chatbot-app .

# Stage 2: Create the minimal final image
FROM alpine:latest
RUN apk --no-cache add ca-certificates
WORKDIR /root/
# Copy the built binary from the builder stage
COPY --from=builder /app/chatbot-app .

# Expose the port your Go app listens on (e.g., 8080)
EXPOSE 8080

# Run the compiled binary
CMD ["./chatbot-app"]