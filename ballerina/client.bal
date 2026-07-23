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
isolated function newFileClient(files:ConnectionConfig config) returns files:FileClient|ai:Error {
    files:FileClient|error fileClient = new (config);
    if fileClient is error {
        return error ai:Error(
            string `Failed to initialize the Azure Files client: ${fileClient.message()}`, fileClient);
    }
    return fileClient;
}

// Constructs the Azure Files `ManagementClient` (used only to enumerate shares for a
// `share: "*"` source via `listShares`), wrapping any construction failure as an `ai:Error`.
isolated function newManagementClient(files:ConnectionConfig config) returns files:ManagementClient|ai:Error {
    files:ManagementClient|error managementClient = new (config);
    if managementClient is error {
        return error ai:Error(
            string `Failed to initialize the Azure Files management client: ${managementClient.message()}`,
            managementClient);
    }
    return managementClient;
}

// Reports whether a connector error denotes a missing resource (share, directory, or file).
// The `files` connector maps every HTTP 404 — regardless of the Azure error code
// (`ShareNotFound`, `ResourceNotFound`, `ParentNotFound`, …) — to a distinct
// `files:NotFoundError` (an `http:STATUS_NOT_FOUND` `ServerError`), so a single typed check
// suffices. The loader uses this to fall back from an explicit-file probe to a
// directory listing, and to tolerate missing paths under a `share: "*"` source.
isolated function isNotFoundError(error err) returns boolean => err is files:NotFoundError;
