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
import ballerina/jballerina.java;
import ballerina/time;

// How a file's content is turned into text, derived from its MIME type / extension.
enum DocumentKind {
    // Inherently textual; decoded directly from its bytes.
    PLAIN_TEXT,
    // A PDF or Microsoft Office document whose text is extracted via Apache Tika
    // (PDFBox for PDF, Apache POI for Office).
    EXTRACTABLE,
    // Cannot be represented as text (images, audio, unknown binary); skipped.
    UNSUPPORTED
}

// Builds an `ai:TextDocument` from downloaded file content, extracting the text of
// PDF documents via Apache Tika. Returns `()` for content that cannot be represented
// as text (images, audio, Office documents, unknown binary), signalling the caller to skip.
isolated function buildDocument(byte[] content, string fileName, string? mimeType, decimal? fileSize,
        string? createdDateTime, string? modifiedDateTime) returns ai:TextDocument?|ai:Error {
    ai:Metadata metadata = {fileName};
    if mimeType is string {
        metadata.mimeType = mimeType;
    }
    if fileSize is decimal {
        metadata.fileSize = fileSize;
    }
    time:Utc? createdAt = toUtc(createdDateTime);
    if createdAt is time:Utc {
        metadata.createdAt = createdAt;
    }
    time:Utc? modifiedAt = toUtc(modifiedDateTime);
    if modifiedAt is time:Utc {
        metadata.modifiedAt = modifiedAt;
    }

    match classify(fileName, mimeType) {
        PLAIN_TEXT => {
            string|error text = string:fromBytes(content);
            if text is error {
                return error ai:Error(
                    string `Failed to decode text content of '${fileName}': ${text.message()}`, text);
            }
            return {content: text, metadata};
        }
        EXTRACTABLE => {
            string|error text = extractText(content, fileName);
            if text is error {
                return error ai:Error(
                    string `Failed to extract text from '${fileName}': ${text.message()}`, text);
            }
            return {content: text, metadata};
        }
    }
    return ();
}

// Extracts plain text from a PDF document using Apache Tika, reading directly from the
// in-memory bytes (no temporary file). `fileName` is passed as a Tika resource-name hint.
// Returns an `error` if the content cannot be parsed.
isolated function extractText(byte[] content, string fileName) returns string|error = @java:Method {
    'class: "io.ballerina.lib.ai.azure.storage.files.TextExtractor",
    name: "extractText"
} external;

// The sentinel phrase the native extractor embeds when a PDF parses successfully but
// yields no text — either a scanned/image-only document or a born-blank one (mirrors
// TextExtractor.SCANNED_PDF_MESSAGE / BLANK_PDF_MESSAGE, which both contain this phrase).
const string TEXTLESS_PDF_SENTINEL = "no extractable text";

// Reports whether an error denotes a text-less PDF (scanned/image-only or blank). The
// loader uses this to skip such files in directory listings (with a warning) — like other
// non-text content — while an explicitly named text-less PDF surfaces the descriptive,
// case-specific error to the caller.
isolated function isTextlessPdfError(error err) returns boolean =>
    err.message().includes(TEXTLESS_PDF_SENTINEL);

// Classifies a file by how its text is obtained, using MIME type then extension.
isolated function classify(string fileName, string? mimeType) returns DocumentKind {
    string mime = (mimeType ?: "").toLowerAscii();
    string extension = getExtension(fileName);
    if mime.startsWith("text/") || (mime != "" && TEXT_MIME_TYPES.indexOf(mime) !is ())
            || TEXT_EXTENSIONS.indexOf(extension) !is () {
        return PLAIN_TEXT;
    }
    // PDF and Microsoft Office documents are extracted via Apache Tika (PDFBox / POI).
    if (mime != "" && EXTRACTABLE_MIME_TYPES.indexOf(mime) !is ())
            || EXTRACTABLE_EXTENSIONS.indexOf(extension) !is () {
        return EXTRACTABLE;
    }
    return UNSUPPORTED;
}

// Returns the lower-cased file extension (without the dot), or `""` if none.
isolated function getExtension(string fileName) returns string {
    int? lastDotIndex = fileName.lastIndexOf(".");
    if lastDotIndex is () {
        return "";
    }
    return fileName.substring(lastDotIndex + 1).toLowerAscii();
}

// Reports whether a file passes the extension allowlist (`()`/empty matches all).
isolated function matchesExtensionFilter(string fileName, string[]? includeExtensions) returns boolean {
    if includeExtensions is () || includeExtensions.length() == 0 {
        return true;
    }
    string extension = getExtension(fileName);
    foreach string allowed in includeExtensions {
        string normalized = allowed.toLowerAscii();
        if normalized.startsWith(".") {
            normalized = normalized.substring(1);
        }
        if normalized == extension {
            return true;
        }
    }
    return false;
}

// Parses an ISO 8601 timestamp into `time:Utc`, or `()` if absent/unparseable.
// Azure Files' directory/file listings report timestamps in RFC 1123 form, which
// `time:utcFromString` does not accept, so those are dropped gracefully (see the README).
isolated function toUtc(string? dateTime) returns time:Utc? {
    if dateTime is () {
        return ();
    }
    time:Utc|error utc = time:utcFromString(dateTime);
    return utc is time:Utc ? utc : ();
}

// Removes duplicate strings, preserving first-appearance order (used to de-dup share
// names returned by a paginated `listShares`).
isolated function dedupeStrings(string[] values) returns string[] {
    string[] result = [];
    map<boolean> seen = {};
    foreach string value in values {
        if !seen.hasKey(value) {
            seen[value] = true;
            result.push(value);
        }
    }
    return result;
}

// MIME types (outside the `text/` family) treated as text.
final readonly & string[] TEXT_MIME_TYPES = [
    "application/json",
    "application/xml",
    "application/xhtml+xml",
    "application/javascript",
    "application/x-yaml",
    "application/yaml",
    "application/csv"
];

// File extensions treated as text.
final readonly & string[] TEXT_EXTENSIONS = [
    "txt", "text", "md", "markdown", "csv", "tsv", "json", "xml", "html", "htm",
    "yaml", "yml", "log", "ini", "conf", "properties", "css", "js", "ts"
];

// MIME types whose text is extracted via Apache Tika: PDF (PDFBox) and Microsoft
// Office documents (POI, via the `tika-parser-microsoft-module`).
final readonly & string[] EXTRACTABLE_MIME_TYPES = [
    "application/pdf",
    "application/msword",
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    "application/vnd.ms-powerpoint",
    "application/vnd.openxmlformats-officedocument.presentationml.presentation",
    "application/vnd.ms-excel",
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
];

// File extensions whose text is extracted via Apache Tika: PDF and Microsoft Office.
final readonly & string[] EXTRACTABLE_EXTENSIONS = [
    "pdf", "doc", "docx", "ppt", "pptx", "xls", "xlsx"
];
