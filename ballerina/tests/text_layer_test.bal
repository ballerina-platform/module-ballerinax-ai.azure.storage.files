// Copyright (c) 2026, WSO2 LLC. (http://www.wso2.com).
//
// WSO2 LLC. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

import ballerina/ai;
import ballerina/test;
import ballerina/time;

// ---- getExtension ------------------------------------------------------------

@test:Config {}
isolated function testGetExtensionBasic() {
    test:assertEquals(getExtension("report.pdf"), "pdf");
    test:assertEquals(getExtension("notes.TXT"), "txt", "Extension is lower-cased");
    test:assertEquals(getExtension("archive.tar.gz"), "gz", "Only the last extension is used");
}

@test:Config {}
isolated function testGetExtensionNoDot() {
    test:assertEquals(getExtension("README"), "", "No dot yields an empty extension");
    test:assertEquals(getExtension("reports/2026/q1"), "", "A path with no dot yields empty");
}

// ---- classify ----------------------------------------------------------------

@test:Config {}
isolated function testClassifyPlainTextByExtension() {
    test:assertEquals(classify("a.txt", ()), PLAIN_TEXT);
    test:assertEquals(classify("a.md", ()), PLAIN_TEXT);
    test:assertEquals(classify("a.json", ()), PLAIN_TEXT);
    test:assertEquals(classify("a.csv", ()), PLAIN_TEXT);
    test:assertEquals(classify("a.html", ()), PLAIN_TEXT);
}

@test:Config {}
isolated function testClassifyPlainTextByMimeType() {
    test:assertEquals(classify("noext", "text/plain"), PLAIN_TEXT, "Any text/* MIME is plain text");
    test:assertEquals(classify("data", "application/json"), PLAIN_TEXT);
    // MIME wins even when the extension is unknown.
    test:assertEquals(classify("weird.bin", "text/markdown"), PLAIN_TEXT);
}

@test:Config {}
isolated function testClassifyExtractablePdf() {
    test:assertEquals(classify("doc.pdf", ()), EXTRACTABLE);
    test:assertEquals(classify("noext", "application/pdf"), EXTRACTABLE);
}

@test:Config {}
isolated function testClassifyExtractableOffice() {
    // Microsoft Office documents are extracted via Apache Tika (POI), same as PDFs.
    test:assertEquals(classify("a.docx", ()), EXTRACTABLE);
    test:assertEquals(classify("a.pptx", ()), EXTRACTABLE);
    test:assertEquals(classify("a.xlsx", ()), EXTRACTABLE);
    test:assertEquals(classify("a.doc", ()), EXTRACTABLE);
    test:assertEquals(classify("a.ppt", ()), EXTRACTABLE);
    test:assertEquals(classify("a.xls", ()), EXTRACTABLE);
    test:assertEquals(
        classify("noext", "application/vnd.openxmlformats-officedocument.presentationml.presentation"),
        EXTRACTABLE);
}

@test:Config {}
isolated function testClassifyUnsupportedBinary() {
    test:assertEquals(classify("photo.png", ()), UNSUPPORTED);
    test:assertEquals(classify("clip.mp3", ()), UNSUPPORTED);
    test:assertEquals(classify("noextension", ()), UNSUPPORTED);
    test:assertEquals(classify("blob", "application/octet-stream"), UNSUPPORTED);
}

// ---- matchesExtensionFilter --------------------------------------------------

@test:Config {}
isolated function testExtensionFilterEmptyMatchesAll() {
    test:assertTrue(matchesExtensionFilter("a.pdf", ()));
    test:assertTrue(matchesExtensionFilter("a.png", []));
}

@test:Config {}
isolated function testExtensionFilterAllowlist() {
    test:assertTrue(matchesExtensionFilter("a.pdf", ["pdf"]));
    test:assertFalse(matchesExtensionFilter("a.txt", ["pdf"]));
}

@test:Config {}
isolated function testExtensionFilterCaseInsensitiveAndDotTolerant() {
    test:assertTrue(matchesExtensionFilter("A.PDF", ["pdf"]), "File extension compared case-insensitively");
    test:assertTrue(matchesExtensionFilter("a.pdf", [".PDF"]), "Leading dot and case tolerated in the allowlist");
    test:assertTrue(matchesExtensionFilter("a.md", ["pdf", ".md", "TXT"]));
}

// ---- toUtc -------------------------------------------------------------------

@test:Config {}
isolated function testToUtcParsesIso8601() {
    time:Utc? utc = toUtc("2024-01-15T10:30:00Z");
    test:assertTrue(utc is time:Utc, "A valid ISO 8601 timestamp parses");
}

@test:Config {}
isolated function testToUtcNilForNilOrUnparseable() {
    test:assertTrue(toUtc(()) is (), "() input yields ()");
    test:assertTrue(toUtc("not-a-timestamp") is (), "Unparseable input yields ()");
}

// ---- extractText (native Apache Tika) ----------------------------------------

@test:Config {}
isolated function testExtractTextFromPdfBytes() returns error? {
    string text = check extractText(PDF_BYTES, "sample.pdf");
    test:assertTrue(text.includes(PDF_TEXT), text);
}

// ---- text-less PDF detection (scanned/image-only or blank) --------------------

@test:Config {}
isolated function testExtractTextFromScannedPdfErrors() {
    // The scanned fixture parses fine but has no text layer; the extractor must surface
    // a descriptive error rather than silently returning an empty string.
    string|error text = extractText(SCANNED_PDF_BYTES, "scan.pdf");
    if text is error {
        test:assertTrue(text.message().includes(TEXTLESS_PDF_SENTINEL), text.message());
    } else {
        test:assertFail("A scanned (image-only) PDF should surface a descriptive error");
    }
}

@test:Config {}
isolated function testExtractTextFromBlankPdfErrors() {
    // A genuinely blank PDF (no text, no images) gets the same neutral message.
    string|error text = extractText(BLANK_PDF_BYTES, "blank.pdf");
    if text is error {
        test:assertTrue(text.message().includes(TEXTLESS_PDF_SENTINEL), text.message());
    } else {
        test:assertFail("A blank PDF should surface a descriptive error");
    }
}

@test:Config {}
isolated function testBuildDocumentScannedPdfErrors() {
    ai:TextDocument?|ai:Error result = buildDocument(SCANNED_PDF_BYTES, "scan.pdf",
            "application/pdf", (), (), ());
    if result is ai:Error {
        test:assertTrue(result.message().includes(TEXTLESS_PDF_SENTINEL), result.message());
        test:assertTrue(isTextlessPdfError(result), "The error must be recognisable as text-less PDF");
    } else {
        test:assertFail("Building a document from a scanned PDF should error, not skip or succeed");
    }
}

@test:Config {}
isolated function testIsTextlessPdfErrorRejectsOtherErrors() {
    test:assertFalse(isTextlessPdfError(error("some unrelated extraction failure")));
    test:assertFalse(isTextlessPdfError(error("Failed to decode text content")));
}

@test:Config {}
isolated function testExtractTextFromDocxBytes() returns error? {
    // The .docx path exercises the POI-backed OOXML parser (tika-parser-microsoft-module).
    string text = check extractText(DOCX_BYTES, "sample.docx");
    test:assertTrue(text.includes(DOCX_TEXT), text);
}

@test:Config {}
isolated function testExtractTextFromXlsxBytes() returns error? {
    // .xlsx exercises the OOXML parser for a spreadsheet.
    string text = check extractText(XLSX_BYTES, "sample.xlsx");
    test:assertTrue(text.includes(XLSX_TEXT), text);
}

@test:Config {}
isolated function testExtractTextFromPptxBytes() returns error? {
    // .pptx exercises the OOXML parser for a presentation (and the embedded-object skip).
    string text = check extractText(PPTX_BYTES, "sample.pptx");
    test:assertTrue(text.includes(PPTX_TEXT), text);
}

@test:Config {}
isolated function testExtractTextFromXlsBytes() returns error? {
    // Legacy .xls exercises the OLE2 OfficeParser for a spreadsheet.
    string text = check extractText(XLS_BYTES, "sample.xls");
    test:assertTrue(text.includes(XLS_TEXT), text);
}

@test:Config {}
isolated function testExtractTextFromPptBytes() returns error? {
    // Legacy .ppt exercises the OLE2 OfficeParser for a presentation.
    string text = check extractText(PPT_BYTES, "sample.ppt");
    test:assertTrue(text.includes(PPT_TEXT), text);
}

// ---- buildDocument: plain-text path ------------------------------------------

@test:Config {}
isolated function testBuildDocumentPlainText() returns error? {
    byte[] bytes = "hello world".toBytes();
    ai:TextDocument? doc = check buildDocument(bytes, "greeting.txt", "text/plain", 11, (), ());
    if doc is ai:TextDocument {
        test:assertEquals(doc.content, "hello world");
        test:assertEquals(doc.metadata?.fileName, "greeting.txt");
        test:assertEquals(doc.metadata?.mimeType, "text/plain");
        test:assertEquals(doc.metadata?.fileSize, <decimal>11);
    } else {
        test:assertFail("A .txt file should build a TextDocument");
    }
}

@test:Config {}
isolated function testBuildDocumentPopulatesTimestamps() returns error? {
    ai:TextDocument? doc = check buildDocument(
        "x".toBytes(), "a.txt", (), (), "2024-01-15T10:30:00Z", "2024-02-20T08:00:00Z");
    if doc is ai:TextDocument {
        test:assertTrue(doc.metadata?.createdAt !is (), "createdAt is populated from a valid timestamp");
        test:assertTrue(doc.metadata?.modifiedAt !is (), "modifiedAt is populated from a valid timestamp");
    } else {
        test:assertFail("Expected a TextDocument");
    }
}

@test:Config {}
isolated function testBuildDocumentDropsUnparseableTimestamp() returns error? {
    ai:TextDocument? doc = check buildDocument("x".toBytes(), "a.txt", (), (), "bad-date", ());
    if doc is ai:TextDocument {
        test:assertTrue(doc.metadata?.createdAt is (), "An unparseable timestamp is dropped, not fatal");
    } else {
        test:assertFail("Expected a TextDocument");
    }
}

@test:Config {}
isolated function testBuildDocumentInvalidUtf8Errors() {
    // 0xFF is not a valid UTF-8 start byte, so decoding a "text" blob fails.
    byte[] invalid = [255, 254, 253];
    ai:TextDocument?|ai:Error result = buildDocument(invalid, "broken.txt", "text/plain", (), (), ());
    if result is ai:Error {
        test:assertTrue(result.message().includes("Failed to decode text"), result.message());
    } else {
        test:assertFail("Invalid UTF-8 text content should surface as an error");
    }
}

// ---- buildDocument: PDF (extractable) path -----------------------------------

@test:Config {}
isolated function testBuildDocumentPdfExtractsText() returns error? {
    ai:TextDocument? doc = check buildDocument(PDF_BYTES, "report.pdf", "application/pdf", 123, (), ());
    if doc is ai:TextDocument {
        test:assertTrue(doc.content.includes(PDF_TEXT), doc.content);
        test:assertEquals(doc.metadata?.fileName, "report.pdf");
        test:assertEquals(doc.metadata?.mimeType, "application/pdf");
    } else {
        test:assertFail("A .pdf file should extract to a TextDocument");
    }
}

// ---- buildDocument: skipped (unsupported) paths ------------------------------

@test:Config {}
isolated function testBuildDocumentUnsupportedBinaryReturnsNil() returns error? {
    // An image cannot be represented as text; buildDocument returns () so the caller skips it.
    ai:TextDocument? doc = check buildDocument([137, 80, 78, 71], "photo.png", "image/png", (), (), ());
    test:assertTrue(doc is (), "A non-text binary yields () (skip)");
}

// ---- buildDocument: Office (extractable) path --------------------------------

@test:Config {}
isolated function testBuildDocumentDocxExtractsText() returns error? {
    ai:TextDocument? doc = check buildDocument(DOCX_BYTES, "summary.docx",
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document", 3518, (), ());
    if doc is ai:TextDocument {
        test:assertTrue(doc.content.includes(DOCX_TEXT), doc.content);
        test:assertEquals(doc.metadata?.fileName, "summary.docx");
    } else {
        test:assertFail("A .docx file should extract to a TextDocument");
    }
}
