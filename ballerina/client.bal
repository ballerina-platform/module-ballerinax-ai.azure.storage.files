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
import ballerinax/azure_storage_service.files;

// Constructs the Azure Files `FileClient` (directory/file listing + download) from the
// connector's `ConnectionConfig`, wrapping any construction failure as an `ai:Error`.
// The connector builds its client from the credential itself, so a construction failure can
// echo the configured `accessKeyOrSAS` back in its message — hence the redaction.
isolated function newFileClient(files:ConnectionConfig config) returns files:FileClient|ai:Error {
    files:FileClient|error fileClient = new (config);
    if fileClient is error {
        return error ai:Error(
            string `Failed to initialize the Azure Files client: ${redactSecrets(fileClient.message())}`,
            fileClient);
    }
    return fileClient;
}

// Reports whether a connector error denotes a missing resource (share, directory, or file).
// The `files` connector maps every HTTP 404 — regardless of the Azure error code
// (`ShareNotFound`, `ResourceNotFound`, `ParentNotFound`, …) — to a distinct
// `files:NotFoundError` (an `http:STATUS_NOT_FOUND` `ServerError`), so a single typed check
// suffices.
//
// This holds only for the operations that call the connector's `checkAndHandleErrors`
// (`getFileAsByteArray` among them). The *listing* operations do not: see `probeDirectory`.
isolated function isNotFoundError(error err) returns boolean => err is files:NotFoundError;

// Azure's error code for "the file you asked for is not there, but its parent is". Returned
// for a `Get File` against a directory that exists.
const string RESOURCE_NOT_FOUND_CODE = "ResourceNotFound";

// Azure's error codes for "something above the file does not exist".
const string PARENT_NOT_FOUND_CODE = "ParentNotFound";
const string SHARE_NOT_FOUND_CODE = "ShareNotFound";

// The byte range a size-bounded download asks for: byte 0 through `maxFileSizeInBytes`
// *inclusive*, which is one byte more than the limit permits. That extra byte is deliberate —
// it is what makes "the file fits" and "the file is too large" distinguishable from the length
// of what came back, without ever reading further into an oversized file (see
// `TextDataLoader.downloadBounded`).
isolated function boundedRange(int maxFileSizeInBytes) returns files:ContentRange =>
    {startByte: 0, endByte: maxFileSizeInBytes};

// Azure's answer (HTTP 416) to a byte range that does not exist in the file.
const string INVALID_RANGE_CODE = "InvalidRange";
const int STATUS_RANGE_NOT_SATISFIABLE = 416;

// Reports whether a connector error is Azure's "that range is not satisfiable" answer.
//
// The loader only ever asks for a range starting at byte 0 (see `downloadBounded`), and the
// sole file without a byte 0 is an empty one, so this identifies a zero-length file. The
// status is checked alongside the code because `checkAndHandleErrors` falls back to a generic
// `ServerError` with `errorCode = "Undefined"` when the 416 body is not XML it can parse.
isolated function isInvalidRangeError(error err) returns boolean {
    if err !is files:ServerError {
        return false;
    }
    files:ServerErrorDetail detail = err.detail();
    return detail.errorCode == INVALID_RANGE_CODE || detail.httpStatus == STATUS_RANGE_NOT_SATISFIABLE;
}

// Reads the Azure error code (`ShareNotFound`, `AuthenticationFailed`, …) carried by a
// connector error, or `()` when the error is not one the connector built from an Azure
// response. Only `files:ServerError` and its sub-types carry the detail record.
isolated function azureErrorCode(error err) returns string? {
    if err is files:ServerError {
        return err.detail().errorCode;
    }
    return ();
}
