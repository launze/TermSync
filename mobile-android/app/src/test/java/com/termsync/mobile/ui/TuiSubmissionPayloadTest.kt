package com.termsync.mobile.ui

import org.junit.Assert.assertEquals
import org.junit.Test

class TuiSubmissionPayloadTest {
    @Test
    fun singleLineIncludesSubmitInTheSamePayload() {
        assertEquals("继续\r", buildTuiSubmissionPayload("继续"))
    }

    @Test
    fun multilinePasteClosesBeforeTheSingleSubmitKey() {
        assertEquals(
            "\u001B[200~first\nsecond\u001B[201~\r",
            buildTuiSubmissionPayload("first\nsecond")
        )
    }

    @Test
    fun escapeOnlyInputDoesNotBecomeAnAccidentalSubmit() {
        assertEquals("", buildTuiSubmissionPayload("\u001B"))
    }
}
