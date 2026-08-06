package com.termsync.mobile.network

import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import okhttp3.OkHttpClient
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

class WssClientTest {
    private lateinit var server: MockWebServer
    private lateinit var client: WssClient
    private val serverMessages = LinkedBlockingQueue<JSONObject>()
    @Volatile
    private var serverSocket: WebSocket? = null

    @Before
    fun setUp() {
        server = MockWebServer()
        server.enqueue(
            MockResponse().withWebSocketUpgrade(object : WebSocketListener() {
                override fun onOpen(webSocket: WebSocket, response: Response) {
                    serverSocket = webSocket
                }

                override fun onMessage(webSocket: WebSocket, text: String) {
                    serverMessages.offer(JSONObject(text))
                }
            })
        )
        server.start()
        client = WssClient(OkHttpClient.Builder().build())
    }

    @After
    fun tearDown() {
        client.disconnect()
        serverSocket?.close(1000, "test complete")
        server.shutdown()
    }

    @Test
    fun applicationMessagesWaitForAuthenticationAndAuthEventIsRetained() = runBlocking {
        val wsUrl = server.url("/ws").toString().replaceFirst("http", "ws")
        client.connect(wsUrl, "mobile-token")

        val auth = serverMessages.poll(2, TimeUnit.SECONDS)
        assertNotNull("client did not send auth", auth)
        assertEquals("auth", auth!!.optString("type"))
        assertFalse(client.isConnected)

        assertFalse(client.subscribeScreen("workspace-1", "pane-1"))
        assertEquals(null, serverMessages.poll(200, TimeUnit.MILLISECONDS))

        assertTrue(
            serverSocket!!.send(
                JSONObject()
                    .put("type", "auth_response")
                    .put(
                        "payload",
                        JSONObject()
                            .put("success", true)
                            .put("device_id", "mobile-1")
                            .put("device_type", "mobile")
                    )
                    .toString()
            )
        )
        waitUntil { client.isConnected }

        // Collection deliberately starts after delivery. A replay=0 SharedFlow
        // lost this event; the channel-backed flow must retain it.
        val authResponse = withTimeout(2_000) {
            client.messages.first { it.type == "auth_response" }
        }
        assertEquals("mobile-1", authResponse.payload?.optString("device_id"))

        assertTrue(client.subscribeScreen("workspace-1", "pane-1"))
        val subscription = serverMessages.poll(2, TimeUnit.SECONDS)
        assertNotNull("authenticated screen subscription was not sent", subscription)
        assertEquals("screen.subscribe", subscription!!.optString("type"))
    }

    @Test
    fun queuedMessagesFromInvalidatedConnectionAreIgnored() = runBlocking {
        val wsUrl = server.url("/ws").toString().replaceFirst("http", "ws")
        client.connect(wsUrl, "mobile-token")
        assertEquals("auth", serverMessages.poll(2, TimeUnit.SECONDS)?.optString("type"))

        serverSocket!!.send(
            JSONObject()
                .put("type", "auth_response")
                .put(
                    "payload",
                    JSONObject()
                        .put("success", true)
                        .put("device_id", "old-mobile")
                        .put("device_type", "mobile")
                )
                .toString()
        )
        waitUntil { client.isConnected }

        client.disconnect()
        val staleMessage = withTimeoutOrNull(300) { client.messages.first() }
        assertNull(staleMessage)
    }

    private fun waitUntil(predicate: () -> Boolean) {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(2)
        while (!predicate() && System.nanoTime() < deadline) {
            Thread.sleep(10)
        }
        assertTrue("condition was not met before timeout", predicate())
    }
}
