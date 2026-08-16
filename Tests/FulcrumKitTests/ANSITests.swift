import Foundation
import Testing
@testable import FulcrumKit

@Test func stripsSGRCodesFromTheDisplayedText() {
    let raw = "[10:28:56] \u{1b}[32mINFO\u{1b}[39m (northwind-catalog-service): up"
    #expect(ANSI.parse(raw).map(\.text).joined() == "[10:28:56] INFO (northwind-catalog-service): up")
}

@Test func capturesTheColourEachSpanWasGiven() {
    let spans = ANSI.parse("\u{1b}[32mgreen\u{1b}[39m plain")
    #expect(spans.first?.colour == .green)
    #expect(spans.last?.colour == nil)
}

@Test func anUnrecognisedEscapeIsRemovedNotRendered() {
    // Raw escape bytes on screen are the failure this test exists to prevent.
    #expect(!ANSI.parse("a\u{1b}[38;5;208mb").map(\.text).joined().contains("\u{1b}"))
}

@Test func aTruncatedEscapeAtEndOfStringDoesNotHang() {
    #expect(ANSI.parse("text\u{1b}[").map(\.text).joined() == "text")
}

@Test func boldIsCapturedAndClearedIndependentlyOfColour() {
    let spans = ANSI.parse("\u{1b}[1mbold\u{1b}[22m plain")
    #expect(spans.first?.bold == true)
    #expect(spans.last?.bold == false)
}

@Test func resetAllClearsBothColourAndBold() {
    let spans = ANSI.parse("\u{1b}[1;31mred bold\u{1b}[0m plain")
    #expect(spans.first?.colour == .red)
    #expect(spans.first?.bold == true)
    #expect(spans.last?.colour == nil)
    #expect(spans.last?.bold == false)
}

@Test func brightForegroundColoursAreCaptured() {
    let spans = ANSI.parse("\u{1b}[93mbright yellow")
    #expect(spans.first?.colour == .brightYellow)
}

@Test func anUnrecognisedCsiSequenceWithANonSGRFinalByteIsRemoved() {
    // Cursor movement etc. — not SGR (final byte is not "m") — must still be
    // stripped, not passed through.
    #expect(ANSI.parse("a\u{1b}[2Ab").map(\.text).joined() == "ab")
}
