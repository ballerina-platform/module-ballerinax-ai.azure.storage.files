# Change Log

This file documents all significant changes made to the Ballerina ai.azure.storage.files package across releases.

## [Un-released]

### Added
- Initial project configuration
- Introduced the `ballerinax/ai.azure.storage.files` data loader, which ingests documents from
  Azure Files shares and returns them as `ai:TextDocument` values for the Ballerina AI module
- Added text extraction for PDF (PDFBox) and Microsoft Office (POI) documents, alongside
  direct decoding of inherently textual files
- Added the `maxFileSizeInBytes` initialization parameter (default 100 MiB), which skips
  oversized files before they are downloaded
