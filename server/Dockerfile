FROM --platform=$BUILDPLATFORM golang:1.26-alpine AS build
WORKDIR /src
COPY server/go.mod server/go.sum ./
RUN go mod download
COPY server/ ./
ARG TARGETOS
ARG TARGETARCH
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -trimpath -ldflags="-s -w" -o /out/witerm-server ./cmd/server

FROM alpine:3.23
RUN apk add --no-cache ca-certificates
COPY --from=build /out/witerm-server /witerm-server
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/witerm-server"]

