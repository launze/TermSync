# TermSync Server Makefile

.PHONY: all build run clean test certs docker

# Variables
BINARY_NAME=termsync-server
CERT_DIR=certs
CERT_FILE=$(CERT_DIR)/server.crt
KEY_FILE=$(CERT_DIR)/server.key

# Default target
all: certs build

# Generate self-signed certificates
certs: $(CERT_FILE) $(KEY_FILE)

$(CERT_FILE) $(KEY_FILE):
	@echo "🔑 Generating self-signed certificates..."
	@mkdir -p $(CERT_DIR)
	@go run ./cmd/gencert

# Build the server
build:
	@echo "🔨 Building $(BINARY_NAME)..."
	@go build -ldflags="-s -w" -o $(BINARY_NAME) .
	@echo "✅ Build complete: $(BINARY_NAME)"

# Run the server
run: build
	@echo "🚀 Starting TermSync Server..."
	@./$(BINARY_NAME)

# Run in development mode with hot reload
dev:
	@echo "🔧 Running in development mode..."
	@go run .

# Run tests
test:
	@echo "🧪 Running tests..."
	@go test -v -race -coverprofile=coverage.out ./...
	@go tool cover -html=coverage.out -o coverage.html
	@echo "✅ Coverage report: coverage.html"

# Clean build artifacts
clean:
	@echo "🧹 Cleaning..."
	@rm -f $(BINARY_NAME)
	@rm -f coverage.out coverage.html
	@rm -rf data/
	@echo "✅ Clean complete"

# Build for Linux
build-linux:
	@echo "🐧 Building for Linux..."
	@GOOS=linux GOARCH=amd64 go build -ldflags="-s -w" -o $(BINARY_NAME)-linux .

# Build for macOS
build-macos:
	@echo "🍎 Building for macOS..."
	@GOOS=darwin GOARCH=amd64 go build -ldflags="-s -w" -o $(BINARY_NAME)-darwin .

# Build for Windows
build-windows:
	@echo "🪟 Building for Windows..."
	@GOOS=windows GOARCH=amd64 go build -ldflags="-s -w" -o $(BINARY_NAME).exe .

# Build all platforms
build-all: build-linux build-macos build-windows

# Create Docker image
docker:
	@echo "🐳 Building Docker image..."
	@docker build -t termsync-server:latest .

# Show certificate fingerprint
fingerprint:
	@echo "🔑 Certificate SHA256 Fingerprint:"
	@openssl x509 -in $(CERT_FILE) -noout -fingerprint -sha256

# Help
help:
	@echo "TermSync Server Makefile"
	@echo ""
	@echo "Targets:"
	@echo "  all           - Generate certs and build (default)"
	@echo "  certs         - Generate self-signed certificates"
	@echo "  build         - Build the server"
	@echo "  run           - Build and run the server"
	@echo "  dev           - Run in development mode"
	@echo "  test          - Run tests with coverage"
	@echo "  clean         - Remove build artifacts"
	@echo "  build-linux   - Build for Linux"
	@echo "  build-macos   - Build for macOS"
	@echo "  build-windows - Build for Windows"
	@echo "  build-all     - Build for all platforms"
	@echo "  docker        - Build Docker image"
	@echo "  fingerprint   - Show certificate fingerprint"
	@echo "  help          - Show this help"
