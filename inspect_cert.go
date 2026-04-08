package main
import (
  "crypto/x509"
  "encoding/pem"
  "fmt"
  "os"
)
func main() {
  data, err := os.ReadFile("server/certs/server.crt")
  if err != nil { panic(err) }
  block, _ := pem.Decode(data)
  if block == nil { panic("pem decode failed") }
  cert, err := x509.ParseCertificate(block.Bytes)
  if err != nil { panic(err) }
  fmt.Println("SUBJECT", cert.Subject)
  fmt.Println("DNS", cert.DNSNames)
  fmt.Println("IPS", cert.IPAddresses)
  fmt.Println("NOT_BEFORE", cert.NotBefore)
  fmt.Println("NOT_AFTER", cert.NotAfter)
}
