/*
 * Copyright (c) 2026, WSO2 LLC. (http://www.wso2.com).
 *
 * WSO2 LLC. licenses this file to you under the Apache License,
 * Version 2.0 (the "License"); you may not use this file except
 * in compliance with the License.
 * You may obtain a copy of the License at
 *
 *    http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package io.ballerina.lib.ai.azure.storage.files;

import io.ballerina.runtime.api.creators.ErrorCreator;
import io.ballerina.runtime.api.creators.TypeCreator;
import io.ballerina.runtime.api.creators.ValueCreator;
import io.ballerina.runtime.api.types.PredefinedTypes;
import io.ballerina.runtime.api.types.TupleType;
import io.ballerina.runtime.api.utils.StringUtils;
import io.ballerina.runtime.api.values.BArray;
import io.ballerina.runtime.api.values.BString;
import org.apache.tika.exception.EncryptedDocumentException;
import org.apache.tika.exception.WriteLimitReachedException;
import org.apache.tika.extractor.EmbeddedDocumentExtractor;
import org.apache.tika.metadata.Metadata;
import org.apache.tika.metadata.TikaCoreProperties;
import org.apache.tika.parser.ParseContext;
import org.apache.tika.parser.Parser;
import org.apache.tika.parser.microsoft.OfficeParser;
import org.apache.tika.parser.microsoft.ooxml.OOXMLParser;
import org.apache.tika.parser.pdf.PDFParser;
import org.apache.tika.parser.pdf.PDFParserConfig;
import org.apache.tika.sax.BodyContentHandler;
import org.xml.sax.ContentHandler;

import java.io.ByteArrayInputStream;
import java.io.InputStream;
import java.nio.ByteBuffer;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.Charset;
import java.nio.charset.CharsetDecoder;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.List;
import java.util.Locale;
import java.util.Set;

/**
 * Extracts plain text from documents using Apache Tika.
 *
 * <p>Supports PDF documents and Microsoft Office formats (.doc/.docx, .ppt/.pptx,
 * .xls/.xlsx): the shipped Tika parser modules are {@code tika-parser-pdf-module} (PDFBox)
 * and {@code tika-parser-microsoft-module} (Apache POI), declared as platform dependencies
 * in {@code Ballerina.toml}. The caller classifies which files are routed here.
 *
 * <p>Unlike {@code ai:TextDataLoader}, which reads from a file path, this reads straight
 * from the in-memory bytes downloaded from Azure Files via a {@link ByteArrayInputStream},
 * so no temporary file is ever written.
 *
 * <p>The concrete parser is selected explicitly from the file extension rather than via
 * {@code AutoDetectParser}. {@code AutoDetectParser} eagerly instantiates every parser
 * registered on the runtime classpath, and in a full Ballerina runtime one of those
 * unrelated parsers fails to initialise against the {@code commons-lang3} version bundled
 * in the runtime. Selecting the exact parser we need ({@link PDFParser}, {@link OOXMLParser},
 * or {@link OfficeParser}) loads only that parser and sidesteps the issue.
 *
 * <p>For the same reason, recursion into <em>embedded</em> objects (thumbnails, OLE objects,
 * attachments) is disabled via a no-op {@link EmbeddedDocumentExtractor}: Office parsers would
 * otherwise route embedded content through {@code AutoDetectParser}'s container detection,
 * which triggers the same {@code commons-lang3} failure. Only the document's own text is
 * needed here, so skipping embedded objects is both a fix and the desired behavior.
 */
public final class TextExtractor {

    /**
     * Upper bound on the number of characters extracted from a single document.
     *
     * <p>A {@code BodyContentHandler} write limit of {@code -1} means "unbounded", which lets
     * one pathological input (a huge spreadsheet, a decompression bomb, a 4 TiB file — Azure
     * Files permits them) exhaust the heap and take the whole process down. Anyone who can
     * write to the share could then halt ingestion at will, so the limit is finite.
     *
     * <p>10 million characters is far beyond any document worth embedding (roughly 2 million
     * words) while capping worst-case retained text at ~20 MB. Exceeding it is not an error:
     * extraction stops and the truncated text is returned, flagged as truncated so the caller
     * can warn, because a partially indexed large document is more useful than a failed load.
     */
    private static final int MAX_EXTRACTED_CHARS = 10_000_000;

    /**
     * The {@code [string, boolean]} pair {@code extractText} returns: the extracted text, and
     * whether it was cut short at {@link #MAX_EXTRACTED_CHARS}. The flag has to travel with the
     * text because truncated output is otherwise indistinguishable from a complete document —
     * it is a plain string of no particular length — so the loader could not report the loss.
     */
    private static final TupleType EXTRACTION_RESULT_TYPE = TypeCreator.createTupleType(
            List.of(PredefinedTypes.TYPE_STRING, PredefinedTypes.TYPE_BOOLEAN));

    /**
     * The phrase shared by every "parsed fine, but there is no text" message. The Ballerina
     * layer matches on it (see {@code isNoExtractableTextError} in {@code utils.bal}) to skip
     * such files in directory listings while surfacing the descriptive message for a path the
     * caller named explicitly. Keep it in sync with {@code NO_EXTRACTABLE_TEXT_SENTINEL}.
     */
    static final String NO_EXTRACTABLE_TEXT_SENTINEL = "no extractable text";

    /**
     * The message for a PDF that parses successfully but yields no text — either a
     * scanned/image-only document or a genuinely blank one. PDFBox extracts only the text
     * layer, so without this check such a PDF would silently produce an empty document. One
     * neutral message covers both cases, since the loader cannot tell them apart without OCR.
     */
    static final String TEXTLESS_PDF_MESSAGE =
            "the PDF contains " + NO_EXTRACTABLE_TEXT_SENTINEL + " content (it may be a "
                    + "scanned/image-only document or an empty one); OCR is not supported";

    /**
     * The message for a non-PDF document that parses successfully but yields no text (an
     * empty or whitespace-only Office file). Without this check such a file would produce an
     * {@code ai:TextDocument} with empty content, which then gets chunked and embedded,
     * polluting the vector store with meaningless vectors.
     */
    static final String TEXTLESS_DOCUMENT_MESSAGE =
            "the document contains " + NO_EXTRACTABLE_TEXT_SENTINEL + " content (it is empty "
                    + "or contains only whitespace)";

    /** The message for a document that cannot be parsed because it is encrypted. */
    static final String ENCRYPTED_DOCUMENT_MESSAGE =
            "the document is password-protected, so its text cannot be extracted";

    /** The message for a file classified as plain text whose bytes are not text at all. */
    static final String NOT_TEXT_MESSAGE =
            "the file is not valid UTF-8, UTF-16 or BOM-marked text; it may be binary content "
                    + "with a text file extension";

    /**
     * The MIME types {@link #selectParser} maps to a parser, mirroring the extractable types
     * the caller's {@code classify} recognises (see {@code EXTRACTABLE_MIME_TYPES} in
     * {@code utils.bal}); keep the two lists in sync.
     */
    private static final String PDF_MIME_TYPE = "application/pdf";
    private static final Set<String> OOXML_MIME_TYPES = Set.of(
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            "application/vnd.openxmlformats-officedocument.presentationml.presentation",
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet");
    private static final Set<String> OLE2_MIME_TYPES = Set.of(
            "application/msword",
            "application/vnd.ms-powerpoint",
            "application/vnd.ms-excel");

    private TextExtractor() {
    }

    /**
     * Extracts the textual content of a document held entirely in memory.
     *
     * @param content  the raw file bytes
     * @param fileName the file name, used to select the parser and as a Tika hint
     * @param mimeType the MIME type when known, which takes precedence over the extension in
     *                 selecting the parser; Ballerina nil (typed {@code Object}, since a
     *                 nilable {@code string?} does not map to {@link BString}) when there is none
     * @return a {@code [text, truncated]} tuple, or a Ballerina error on failure
     */
    public static Object extractText(BArray content, BString fileName, Object mimeType) {
        byte[] bytes = content.getBytes();
        Parser parser = selectParser(fileName.getValue(),
                mimeType instanceof BString mime ? mime.getValue() : null);
        BodyContentHandler handler = new BodyContentHandler(MAX_EXTRACTED_CHARS);
        try (InputStream stream = new ByteArrayInputStream(bytes)) {
            Metadata metadata = new Metadata();
            metadata.set(TikaCoreProperties.RESOURCE_NAME_KEY, fileName.getValue());
            ParseContext context = new ParseContext();
            context.set(EmbeddedDocumentExtractor.class, SkipEmbeddedExtractor.INSTANCE);
            // OCR is not supported (no Tesseract shipped): disable the PDF parser's OCR
            // fallback explicitly, otherwise it NPEs trying to OCR image-only pages.
            PDFParserConfig pdfConfig = new PDFParserConfig();
            pdfConfig.setOcrStrategy(PDFParserConfig.OCR_STRATEGY.NO_OCR);
            context.set(PDFParserConfig.class, pdfConfig);
            parser.parse(stream, handler, metadata, context);
        } catch (WriteLimitReachedException e) {
            // The document is larger than MAX_EXTRACTED_CHARS. The handler still holds
            // everything read up to the limit, so return that rather than failing the file:
            // a truncated document is more useful to a knowledge base than none. The caller
            // logs a warning off the flag, since the text alone does not reveal the loss.
            return extractionResult(handler.toString(), true);
        } catch (EncryptedDocumentException | org.apache.poi.EncryptedDocumentException e) {
            // Password-protected files are common on shared drives and the generic Tika
            // message for them is opaque, so report the cause the user can act on.
            return ErrorCreator.createError(StringUtils.fromString(ENCRYPTED_DOCUMENT_MESSAGE));
        } catch (Exception e) {
            String message = e.getMessage();
            return ErrorCreator.createError(StringUtils.fromString(
                    message != null ? message : e.getClass().getSimpleName()));
        }
        String text = handler.toString();
        // A document that parses but yields no text would otherwise become an ai:TextDocument
        // with empty content, which is then chunked and embedded into the vector store as a
        // meaningless vector. Surface a descriptive error instead and let the loader skip it.
        if (text.trim().isEmpty()) {
            return ErrorCreator.createError(StringUtils.fromString(
                    parser instanceof PDFParser ? TEXTLESS_PDF_MESSAGE : TEXTLESS_DOCUMENT_MESSAGE));
        }
        return extractionResult(text, false);
    }

    /** Builds the {@code [text, truncated]} tuple returned to the Ballerina layer. */
    private static BArray extractionResult(String text, boolean truncated) {
        BArray result = ValueCreator.createTupleValue(EXTRACTION_RESULT_TYPE);
        result.add(0, StringUtils.fromString(text));
        result.add(1, truncated);
        return result;
    }

    /**
     * Decodes an inherently textual file (.txt, .csv, .json, …) into a string.
     *
     * <p>Azure Files is an SMB share, so plain-text files written by Windows tooling are
     * routinely UTF-16LE or UTF-8-with-BOM rather than plain UTF-8. Decoding strict UTF-8 (as
     * {@code string:fromBytes} does) fails outright on the former and leaves a stray
     * {@code U+FEFF} at the head of the content on the latter, which then flows into every
     * chunk and embedding.
     *
     * <p>Detection is deterministic rather than statistical: a byte-order mark decides the
     * charset when present, otherwise strict UTF-8 is attempted, and only then is a BOM-less
     * UTF-16 file recognised from its NUL-byte pattern. Content that is not text in any of
     * those encodings yields an error, which the caller logs and skips.
     *
     * @param content the raw file bytes
     * @return the decoded text as a {@link BString}, or a Ballerina error if it is not text
     */
    public static Object decodeText(BArray content) {
        byte[] bytes = content.getBytes();
        Charset bomCharset = charsetFromBom(bytes);
        if (bomCharset != null) {
            // Decoded strictly, and with the mark itself dropped: a surviving U+FEFF would
            // otherwise head the content and flow into every chunk and embedding. A BOM on
            // bytes that are then malformed (a truncated file, or binary that merely opens
            // with FF FE) is not text, so it falls through to the error below.
            int bomLength = bomLength(bomCharset);
            byte[] body = Arrays.copyOfRange(bytes, bomLength, bytes.length);
            String decoded = decodeStrict(body, bomCharset);
            if (decoded != null) {
                return StringUtils.fromString(decoded);
            }
            return ErrorCreator.createError(StringUtils.fromString(NOT_TEXT_MESSAGE));
        }
        // The BOM-less UTF-16 check has to run before UTF-8, not after it. ASCII-range text
        // encoded as UTF-16 is *also* well-formed UTF-8 — the interleaved NULs simply decode
        // as U+0000 — so trying UTF-8 first would always win and yield a string with a NUL
        // between every character. Genuine UTF-8 text does not carry a regular NUL pattern,
        // so this ordering costs nothing.
        Charset utf16 = guessBomlessUtf16(bytes);
        if (utf16 != null) {
            String decoded = decodeStrict(bytes, utf16);
            if (decoded != null) {
                return StringUtils.fromString(decoded);
            }
        }
        String utf8 = decodeStrict(bytes, StandardCharsets.UTF_8);
        if (utf8 != null) {
            return StringUtils.fromString(utf8);
        }
        return ErrorCreator.createError(StringUtils.fromString(NOT_TEXT_MESSAGE));
    }

    /** Returns the charset indicated by a leading byte-order mark, or {@code null}. */
    private static Charset charsetFromBom(byte[] bytes) {
        if (bytes.length >= 3 && (bytes[0] & 0xFF) == 0xEF && (bytes[1] & 0xFF) == 0xBB
                && (bytes[2] & 0xFF) == 0xBF) {
            return StandardCharsets.UTF_8;
        }
        if (bytes.length >= 2 && (bytes[0] & 0xFF) == 0xFF && (bytes[1] & 0xFF) == 0xFE) {
            return StandardCharsets.UTF_16LE;
        }
        if (bytes.length >= 2 && (bytes[0] & 0xFF) == 0xFE && (bytes[1] & 0xFF) == 0xFF) {
            return StandardCharsets.UTF_16BE;
        }
        return null;
    }

    private static int bomLength(Charset charset) {
        return charset.equals(StandardCharsets.UTF_8) ? 3 : 2;
    }

    /**
     * Decodes with malformed- and unmappable-input reporting enabled, returning {@code null}
     * when the bytes are not valid in that charset. The permissive default would instead
     * substitute U+FFFD and silently produce mojibake.
     */
    private static String decodeStrict(byte[] bytes, Charset charset) {
        CharsetDecoder decoder = charset.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT);
        try {
            return decoder.decode(ByteBuffer.wrap(bytes)).toString();
        } catch (CharacterCodingException e) {
            return null;
        }
    }

    /**
     * Recognises BOM-less UTF-16 from its NUL-byte pattern, returning the charset or
     * {@code null}. Text in the ASCII range encodes as a NUL paired with each character, so a
     * strong imbalance of NULs between even and odd offsets identifies the endianness. Binary
     * content rarely shows that regularity, and requiring a clear majority keeps this from
     * firing on a file that merely contains a few NULs.
     */
    private static Charset guessBomlessUtf16(byte[] bytes) {
        if (bytes.length < 2) {
            return null;
        }
        int evenNuls = 0;
        int oddNuls = 0;
        int examined = Math.min(bytes.length, 4096);
        for (int i = 0; i < examined; i++) {
            if (bytes[i] == 0) {
                if (i % 2 == 0) {
                    evenNuls++;
                } else {
                    oddNuls++;
                }
            }
        }
        int pairs = examined / 2;
        if (pairs == 0) {
            return null;
        }
        // UTF-16LE puts the NUL at the odd offset of each pair, UTF-16BE at the even one.
        if (oddNuls > pairs * 0.7 && evenNuls < pairs * 0.1) {
            return StandardCharsets.UTF_16LE;
        }
        if (evenNuls > pairs * 0.7 && oddNuls < pairs * 0.1) {
            return StandardCharsets.UTF_16BE;
        }
        return null;
    }

    /**
     * Selects the Tika parser for a file. OOXML (.docx/.xlsx/.pptx) and legacy OLE2
     * (.doc/.xls/.ppt) Office formats use POI; everything else this method is called with is a
     * PDF (the caller only routes PDF/Office here), which uses PDFBox.
     *
     * <p>A known MIME type decides on its own and the extension is consulted only otherwise,
     * matching the precedence the caller's {@code classify} uses. Falling back to the extension
     * first would send a file the caller classified from its MIME type alone — an Office
     * document under an extension-less name, say — into the {@link PDFParser} default.
     */
    private static Parser selectParser(String fileName, String mimeType) {
        if (mimeType != null) {
            String mime = mimeType.toLowerCase(Locale.ROOT);
            if (OOXML_MIME_TYPES.contains(mime)) {
                return new OOXMLParser();
            }
            if (OLE2_MIME_TYPES.contains(mime)) {
                return new OfficeParser();
            }
            if (PDF_MIME_TYPE.equals(mime)) {
                return new PDFParser();
            }
        }
        String name = fileName.toLowerCase(Locale.ROOT);
        if (name.endsWith(".docx") || name.endsWith(".xlsx") || name.endsWith(".pptx")) {
            return new OOXMLParser();
        }
        if (name.endsWith(".doc") || name.endsWith(".xls") || name.endsWith(".ppt")) {
            return new OfficeParser();
        }
        return new PDFParser();
    }

    /**
     * An {@link EmbeddedDocumentExtractor} that skips every embedded object, so parsing never
     * recurses into embedded content (see the class Javadoc for why this matters here).
     */
    private static final class SkipEmbeddedExtractor implements EmbeddedDocumentExtractor {
        static final SkipEmbeddedExtractor INSTANCE = new SkipEmbeddedExtractor();

        @Override
        public boolean shouldParseEmbedded(Metadata metadata) {
            return false;
        }

        @Override
        public void parseEmbedded(InputStream stream, ContentHandler handler, Metadata metadata,
                                  boolean outputHtml) {
            // Intentionally a no-op: embedded objects are not extracted.
        }
    }
}
