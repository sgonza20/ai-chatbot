# Stage 1: Build the Go application
FROM golang:1.25-alpine AS builder
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .


# CGO_ENABLED=0 is important for creating statically linked binaries
RUN CGO_ENABLED=0 GOOS=linux go build -o /app/main ./main.go

# Stage 2: Create the minimal final image
FROM alpine:latest
RUN apk add --no-cache ca-certificates
WORKDIR /root/
# Copy the built binary from the builder stage
COPY --from=builder /app/main /app/main

# Expose the port your Go app listens on (e.g., 8080)
EXPOSE 8080

ENV PORT=8080

# Run the compiled binary
CMD ["/app/main"]