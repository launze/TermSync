package com.termsync.mobile.viewmodel

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

class TerminalInputIdGeneratorTest {
    @Test
    fun generatesDistinctIdsForRapidInputs() {
        val generator = TerminalInputIdGenerator(instanceId = "test-instance")

        assertEquals("android:test-instance:1", generator.next())
        assertEquals("android:test-instance:2", generator.next())
    }

    @Test
    fun instancesDoNotReuseIds() {
        assertNotEquals(
            TerminalInputIdGenerator(instanceId = "first").next(),
            TerminalInputIdGenerator(instanceId = "second").next()
        )
    }
}
