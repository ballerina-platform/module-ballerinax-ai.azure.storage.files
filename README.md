# module-ballerinax-ai.azure.storage.files

A Ballerina data loader that ingests documents from **Azure Files** shares and returns them
as `ai:TextDocument` values for the Ballerina AI module (chunking, embedding, RAG ingestion).

- **Package:** `ballerinax/ai.azure.storage.files`
- **Acquisition layer:** the [`ballerinax/azure_storage_service.files`](https://central.ballerina.io/ballerinax/azure_storage_service.files) connector (auth, directory/file listing, download).
- **Text extraction:** direct decode for textual files; Apache Tika for PDFs (PDFBox) and Microsoft Office documents (POI).
- **Authentication:** Shared Access Signature (SAS) and Shared Key (account access key). Azure AD / OAuth2 is not supported in this version.

> **Note:** listings are not paginated. The connector does not surface Azure's `NextMarker`,
> so a directory returns at most the first page of 5,000 entries. See the limitations section
> of the [module README](ballerina/README.md).

## Building

```bash
./gradlew build
```

The Gradle build requires the `packageUser`/`packagePAT` environment variables (a GitHub
account + PAT with `read:packages`) to resolve the `io.ballerina.plugin` Gradle plugin from
GitHub Packages.

## Contributing

Please refer to the [Ballerina Contribution Guidelines](https://github.com/ballerina-platform/ballerina-lang/blob/master/CONTRIBUTING.md).

## License

All the contents in this repository are licensed under the [Apache License, Version 2.0](http://www.apache.org/licenses/LICENSE-2.0).
