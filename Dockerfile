# Stage 1: Build the Go application
FROM golang:1.25-alpine AS builder
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .


RUN CGO_ENABLED=0 GOOS=linux go build -o /app/main ./main.go

FROM alpine:latest
RUN apk add --no-cache ca-certificates
WORKDIR /root/
COPY --from=builder /app/main /app/main

EXPOSE 8080

ENV PORT=8080

CMD ["/app/main"]
