package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"fmt"
	"math/big"
	"net"
	"os"
	"time"
)

// GenerateSelfSignedCert generates a self-signed certificate for TermSync server
func GenerateSelfSignedCert(certPath, keyPath string) error {
	// Generate ECDSA private key
	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return fmt.Errorf("failed to generate private key: %w", err)
	}

	// Certificate template
	template := x509.Certificate{
		SerialNumber: big.NewInt(time.Now().UnixNano()),
		Subject: pkix.Name{
			Organization: []string{"TermSync"},
			CommonName:   "nas.smarthome2020.top",
		},
		NotBefore:             time.Now(),
		NotAfter:              time.Now().AddDate(10, 0, 0), // 10 years validity
		KeyUsage:              x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
		IPAddresses: []net.IP{
			net.ParseIP("127.0.0.1"),
			net.ParseIP("0.0.0.0"),
		},
		DNSNames: []string{
			"localhost",
			"termsync.local",
			"nas.smarthome2020.top",
			"nas.marthome2020.top",
		},
	}

	// Self-sign the certificate
	derBytes, err := x509.CreateCertificate(rand.Reader, &template, &template, &priv.PublicKey, priv)
	if err != nil {
		return fmt.Errorf("failed to create certificate: %w", err)
	}

	// Write certificate file
	certFile, err := os.Create(certPath)
	if err != nil {
		return fmt.Errorf("failed to create cert file: %w", err)
	}
	defer certFile.Close()

	if err := pem.Encode(certFile, &pem.Block{Type: "CERTIFICATE", Bytes: derBytes}); err != nil {
		return fmt.Errorf("failed to encode certificate: %w", err)
	}

	// Write private key file
	keyFile, err := os.Create(keyPath)
	if err != nil {
		return fmt.Errorf("failed to create key file: %w", err)
	}
	defer keyFile.Close()

	b, err := x509.MarshalECPrivateKey(priv)
	if err != nil {
		return fmt.Errorf("failed to marshal private key: %w", err)
	}

	if err := pem.Encode(keyFile, &pem.Block{Type: "EC PRIVATE KEY", Bytes: b}); err != nil {
		return fmt.Errorf("failed to encode private key: %w", err)
	}

	fmt.Printf("✅ Certificate generated: %s\n", certPath)
	fmt.Printf("✅ Private key generated: %s\n", keyPath)

	// Print SHA256 fingerprint for mobile app configuration
	fingerprint := sha256Fingerprint(derBytes)
	fmt.Printf("\n🔑 SHA256 Fingerprint: %s\n", fingerprint)
	fmt.Println("\n📱 Please embed this certificate in:")
	fmt.Println("   - Android: res/raw/server_cert.crt")
	fmt.Println("   - Desktop: assets/server.crt")

	return nil
}

func sha256Fingerprint(derBytes []byte) string {
	hash := sha256Sum(derBytes)
	var fingerprint string
	for i, b := range hash {
		if i > 0 {
			fingerprint += ":"
		}
		fingerprint += fmt.Sprintf("%02X", b)
	}
	return fingerprint
}

func sha256Sum(data []byte) []byte {
	h := sha256.Sum256(data)
	return h[:]
}

func main() {
	certPath := "certs/server.crt"
	keyPath := "certs/server.key"

	// Create certs directory if not exists
	os.MkdirAll("certs", 0755)

	if err := GenerateSelfSignedCert(certPath, keyPath); err != nil {
		fmt.Fprintf(os.Stderr, "❌ Error: %v\n", err)
		os.Exit(1)
	}
}
