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

import ballerina/test;
import ballerinax/azure_storage_service.files;

// A stand-in for a Shared Key credential, derived at run time from a plainly fake phrase
// rather than written out as a base64 literal. `newFileClient` only needs the value to be
// well-formed base64 — nothing decodes or signs with it, since constructing a client makes no
// network call — and a literal of that shape is indistinguishable from a real account key to a
// secret scanner, which flags every commit that carries one.
final string FAKE_ACCESS_KEY = "not-a-real-key-this-value-only-exists-in-unit-tests".toBytes().toBase64();

// ---- newFileClient construction (no network call at init) -------------------

@test:Config {}
isolated function testNewFileClientWithSas() returns error? {
    files:ConnectionConfig config = {
        accountName: "contosostorage",
        accessKeyOrSAS: "sv=2022-11-02&ss=f&srt=co&sp=rl&sig=abc",
        authorizationMethod: files:SAS
    };
    files:FileClient _ = check newFileClient(config);
}

@test:Config {}
isolated function testNewFileClientWithAccessKey() returns error? {
    files:ConnectionConfig config = {
        accountName: "contosostorage",
        accessKeyOrSAS: FAKE_ACCESS_KEY,
        authorizationMethod: files:ACCESS_KEY
    };
    files:FileClient _ = check newFileClient(config);
}

// ---- newManagementClient construction (used for share: "*") -----------------

@test:Config {}
isolated function testNewManagementClientWithSas() returns error? {
    files:ConnectionConfig config = {
        accountName: "contosostorage",
        accessKeyOrSAS: "sv=2022-11-02&ss=f&srt=s&sp=l&sig=abc",
        authorizationMethod: files:SAS
    };
    files:ManagementClient _ = check newManagementClient(config);
}

// ---- isNotFoundError ---------------------------------------------------------

@test:Config {}
isolated function testIsNotFoundErrorForNotFound() {
    files:NotFoundError notFound = error("Resource not found.",
        httpStatus = 404, errorCode = "ShareNotFound", message = "The specified share does not exist.");
    test:assertTrue(isNotFoundError(notFound), "A connector NotFoundError is recognised");
}

@test:Config {}
isolated function testIsNotFoundErrorForOtherErrors() {
    files:BadRequestError badRequest = error("Bad request received.",
        httpStatus = 400, errorCode = "InvalidUri", message = "The request URI is invalid.");
    test:assertFalse(isNotFoundError(badRequest), "A 400 is not a not-found");
    test:assertFalse(isNotFoundError(error("some unrelated failure")), "A generic error is not a not-found");
}
