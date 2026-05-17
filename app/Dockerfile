FROM golang:1.24-alpine AS builder
WORKDIR /src
COPY go.mod ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/shop-api .

FROM alpine:3.20
RUN adduser -D -u 10001 app
USER app
COPY --from=builder /out/shop-api /shop-api
EXPOSE 5000
ENTRYPOINT ["/shop-api"]
