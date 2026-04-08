# TermSync Server Dockerfile
FROM scratch

# Copy the binary
COPY termsync-server /termsync-server

# Copy certificates
COPY certs/ /certs/

# Expose ports
EXPOSE 7373
EXPOSE 8080

# Create data directory volume
VOLUME ["/data"]

# Set working directory
WORKDIR /

# Run the server
ENTRYPOINT ["/termsync-server"]
