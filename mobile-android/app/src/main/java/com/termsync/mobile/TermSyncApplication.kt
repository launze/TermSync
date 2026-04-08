package com.termsync.mobile

import android.app.Application
import android.util.Log
import java.security.KeyStore
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import javax.net.ssl.SSLContext
import javax.net.ssl.TrustManagerFactory
import javax.net.ssl.X509TrustManager

/**
 * TermSync Application class
 * Initializes global components including TLS certificate trust
 */
class TermSyncApplication : Application() {

    companion object {
        private const val TAG = "TermSyncApplication"
        lateinit var sslContext: SSLContext
            private set
        lateinit var trustManager: X509TrustManager
            private set
    }

    override fun onCreate() {
        super.onCreate()
        initializeTLS()
    }

    /**
     * Initialize SSL context with our self-signed certificate
     * This allows the app to trust the TTY1 server's self-signed certificate
     */
    private fun initializeTLS() {
        try {
            // Load the self-signed certificate from raw resources
            val certificateFactory = CertificateFactory.getInstance("X.509")
            val inputStream = resources.openRawResource(R.raw.server_cert)
            
            val certificate = certificateFactory.generateCertificate(inputStream) as X509Certificate
            inputStream.close()
            
            Log.d(TAG, "Loaded certificate: ${certificate.subjectDN}")
            Log.d(TAG, "SHA256 Fingerprint: ${getCertificateFingerprint(certificate)}")

            // Create a KeyStore containing our trusted CAs
            val keyStoreType = KeyStore.getDefaultType()
            val keyStore = KeyStore.getInstance(keyStoreType)
            keyStore.load(null, null)
            keyStore.setCertificateEntry("termsync_ca", certificate)

            // Create a TrustManager that trusts the CAs in our KeyStore
            val tmfAlgorithm = TrustManagerFactory.getDefaultAlgorithm()
            val trustManagerFactory = TrustManagerFactory.getInstance(tmfAlgorithm)
            trustManagerFactory.init(keyStore)
            trustManager = trustManagerFactory.trustManagers[0] as X509TrustManager

            // Create an SSLContext that uses our TrustManager
            sslContext = SSLContext.getInstance("TLS")
            sslContext.init(null, arrayOf(trustManager), null)
            
            Log.d(TAG, "TLS initialized successfully")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to initialize TLS", e)
            // Fallback to default SSL context
            sslContext = SSLContext.getDefault()
            val trustManagerFactory = TrustManagerFactory.getInstance(
                TrustManagerFactory.getDefaultAlgorithm()
            )
            trustManagerFactory.init(null as KeyStore?)
            trustManager = trustManagerFactory.trustManagers[0] as X509TrustManager
        }
    }

    /**
     * Get SHA256 fingerprint of certificate for verification
     */
    private fun getCertificateFingerprint(cert: X509Certificate): String {
        val digest = java.security.MessageDigest.getInstance("SHA-256")
        val hash = digest.digest(cert.encoded)
        return hash.joinToString(":") { "%02X".format(it) }
    }
}
