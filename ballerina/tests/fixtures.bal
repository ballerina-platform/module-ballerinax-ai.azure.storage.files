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

import ballerina/io;

// Real, minimal document fixtures whose text is extracted by Apache Tika via the
// loader's native extractor. Both a PDF (PDFBox) and a Microsoft Word .docx (POI, via
// the tika-parser-microsoft-module) are covered; each was generated and verified to
// round-trip through Tika, so `buildDocument` returns an `ai:TextDocument` whose content
// contains the corresponding marker text.

// A valid PDF (PDFBox) whose only text is `PDF_TEXT`.
final readonly & byte[] PDF_BYTES = base64 `JVBERi0xLjYKJfbk/N8KMSAwIG9iago8PAovVHlwZSAvQ2F0YWxvZwovVmVyc2lvbiAvMS42Ci9QYWdlcyAyIDAgUgo+PgplbmRvYmoKNyAwIG9iago8PAovTGVuZ3RoIDYzCi9GaWx0ZXIgL0ZsYXRlRGVjb2RlCj4+CnN0cmVhbQ0KeJxzCuHSdzNUMDRSCEnjMjdSMDcwUAhJ4dLwzU/OVghwcVNIyU8uzU3NK1EoSa0o0dNUCMnicg3hAgB6Ew6iDQplbmRzdHJlYW0KZW5kb2JqCjggMCBvYmoKPDwKL0xlbmd0aCAxODcKL1R5cGUgL09ialN0bQovTiA1Ci9GaWx0ZXIgL0ZsYXRlRGVjb2RlCi9GaXJzdCAyNwo+PgpzdHJlYW0NCnicVY7dCoJAEIVf5TxB4/qLIEJKEUQQFnQhXpgushC74WrU2zcq9HMxA+ebMzPHhQMPvgsfwosRQAQhQohIIEno/LpL0LHupAXtVWtRerxQoALlZtQDBNL03wk6yFbVmXmidFYOpgqFyz2Kp15Ntl7yrjufokJaM/YNv/AXkBs98NwimvXyYMuQ4/0AwTm/cgkwu+g0XodZTlCAstrKZbKTt4ccVFODNroxrdId6KL0Wlv1AXzwDSMNTM0NCmVuZHN0cmVhbQplbmRvYmoKOSAwIG9iago8PAovTGVuZ3RoIDMzCi9Sb290IDEgMCBSCi9JRCBbPDJCNjNCNTM5MzY2MDE0NTkyNDVCQTYwN0Y4RTRERjNFNTJENUZBNUZEMjBCQTVGQjc1QUNGMjJDRUUzQzE4NTM+IDwyQjYzQjUzOTM2NjAxNDU5MjQ1QkE2MDdGOEU0REYzRTUyRDVGQTVGRDIwQkE1RkI3NUFDRjIyQ0VFM0MxODUzPl0KL1R5cGUgL1hSZWYKL1NpemUgMTAKL0luZGV4IFswIDldCi9XIFsxIDEgMV0KL0ZpbHRlciAvRmxhdGVEZWNvZGUKPj4Kc3RyZWFtDQp4nGNg+M/Iz8DEAUSMTBxMTBzMTBwsjH4MjNcYACDYAnINCmVuZHN0cmVhbQplbmRvYmoKc3RhcnR4cmVmCjUwNAolJUVPRgo=`;

// The marker text Tika extracts from the PDF fixture above.
const string PDF_TEXT = "Mock PDF document text.";

// A valid "scanned-style" PDF: one page holding only an image XObject and NO text
// operators — structurally what a scanner produces. PDFBox parses it fine but extracts
// zero text, which the extractor must surface as a descriptive error (never an empty
// document).
final readonly & byte[] SCANNED_PDF_BYTES = base64 `JVBERi0xLjQKMSAwIG9iago8PCAvVHlwZSAvQ2F0YWxvZyAvUGFnZXMgMiAwIFIgPj4KZW5kb2JqCjIgMCBvYmoKPDwgL1R5cGUgL1BhZ2VzIC9LaWRzIFszIDAgUl0gL0NvdW50IDEgPj4KZW5kb2JqCjMgMCBvYmoKPDwgL1R5cGUgL1BhZ2UgL1BhcmVudCAyIDAgUiAvTWVkaWFCb3ggWzAgMCA2MTIgNzkyXSAvUmVzb3VyY2VzIDw8IC9YT2JqZWN0IDw8IC9JbTAgNCAwIFIgPj4gPj4gL0NvbnRlbnRzIDUgMCBSID4+CmVuZG9iago0IDAgb2JqCjw8IC9UeXBlIC9YT2JqZWN0IC9TdWJ0eXBlIC9JbWFnZSAvV2lkdGggMiAvSGVpZ2h0IDIgL0NvbG9yU3BhY2UgL0RldmljZVJHQiAvQml0c1BlckNvbXBvbmVudCA4IC9MZW5ndGggMTIgPj4Kc3RyZWFtCsjIyFpaWlpaWsjIyAplbmRzdHJlYW0KZW5kb2JqCjUgMCBvYmoKPDwgL0xlbmd0aCAzNCA+PgpzdHJlYW0KcSA0MDAgMCAwIDUwMCAxMDAgMTUwIGNtIC9JbTAgRG8gUQplbmRzdHJlYW0KZW5kb2JqCnhyZWYKMCA2CjAwMDAwMDAwMDAgNjU1MzUgZiAKMDAwMDAwMDAwOSAwMDAwMCBuIAowMDAwMDAwMDU4IDAwMDAwIG4gCjAwMDAwMDAxMTUgMDAwMDAgbiAKMDAwMDAwMDI0NSAwMDAwMCBuIAowMDAwMDAwNDAwIDAwMDAwIG4gCnRyYWlsZXIKPDwgL1NpemUgNiAvUm9vdCAxIDAgUiA+PgpzdGFydHhyZWYKNDg0CiUlRU9GCg==`;

// A valid but genuinely BLANK PDF: one page with an empty content stream — no text and
// no images. Yields the same "no extractable text content" error as the scanned PDF
// (one neutral message covers both cases).
final readonly & byte[] BLANK_PDF_BYTES = base64 `JVBERi0xLjQKMSAwIG9iago8PCAvVHlwZSAvQ2F0YWxvZyAvUGFnZXMgMiAwIFIgPj4KZW5kb2JqCjIgMCBvYmoKPDwgL1R5cGUgL1BhZ2VzIC9LaWRzIFszIDAgUl0gL0NvdW50IDEgPj4KZW5kb2JqCjMgMCBvYmoKPDwgL1R5cGUgL1BhZ2UgL1BhcmVudCAyIDAgUiAvTWVkaWFCb3ggWzAgMCA2MTIgNzkyXSAvQ29udGVudHMgNCAwIFIgPj4KZW5kb2JqCjQgMCBvYmoKPDwgL0xlbmd0aCAwID4+CnN0cmVhbQoKZW5kc3RyZWFtCmVuZG9iagp4cmVmCjAgNQowMDAwMDAwMDAwIDY1NTM1IGYgCjAwMDAwMDAwMDkgMDAwMDAgbiAKMDAwMDAwMDA1OCAwMDAwMCBuIAowMDAwMDAwMTE1IDAwMDAwIG4gCjAwMDAwMDAyMDIgMDAwMDAgbiAKdHJhaWxlcgo8PCAvU2l6ZSA1IC9Sb290IDEgMCBSID4+CnN0YXJ0eHJlZgoyNTEKJSVFT0YK`;

// Microsoft Office fixtures, read from test resource files (each verified to round-trip
// through Tika's POI-backed parsers — OOXML for .docx/.xlsx/.pptx, OLE2 for .doc/.xls/.ppt).
// Kept as files rather than inline base64 literals because they exceed the base64-literal
// size the compiler accepts. Each carries a unique marker in its body text.
final readonly & byte[] DOCX_BYTES = loadResource("office-fixture.docx");
final readonly & byte[] XLSX_BYTES = loadResource("office-report.xlsx");
final readonly & byte[] PPTX_BYTES = loadResource("office-report.pptx");
final readonly & byte[] XLS_BYTES = loadResource("office-legacy.xls");
final readonly & byte[] PPT_BYTES = loadResource("office-legacy.ppt");

// The marker text Tika extracts from each Office fixture above.
const string DOCX_TEXT = "OFFICE_FIXTURE_OK";
const string XLSX_TEXT = "OFFICE_MARKER_XLSX";
const string PPTX_TEXT = "OFFICE_MARKER_PPTX";
const string XLS_TEXT = "OFFICE_MARKER_XLS";
const string PPT_TEXT = "OFFICE_MARKER_PPT";

isolated function loadResource(string name) returns readonly & byte[] {
    byte[]|io:Error bytes = io:fileReadBytes("tests/resources/" + name);
    if bytes is byte[] {
        return bytes.cloneReadOnly();
    }
    panic error("Failed to read the test fixture '" + name + "': " + bytes.message());
}
