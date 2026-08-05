# Change Log

This file documents all significant changes made to the Ballerina ai.azure.storage.files package across releases.

## [Un-released]

### Added
- Initial project configuration
- Introduced the `ballerinax/ai.azure.storage.files` data loader, which ingests documents from
  Azure Files shares and returns them as `ai:TextDocument` values for the Ballerina AI module
- Added text extraction for PDF (PDFBox) and Microsoft Office (POI) documents, alongside
  direct decoding of inherently textual files
- Added the `maxFileSizeInBytes` initialization parameter (default `104857600`, i.e. 100 MiB),
  which bounds the size of a file the loader will convert. A file found in a directory listing
  is skipped with a warning; a file named explicitly in `paths` is reported as an error

### Changed
- Moved the file size limit from the per-source `Source.maxFileSizeInBytes` field, which has
  been removed, to the third `TextDataLoader` initialization parameter, where a single value now
  applies to every source. The field only ever existed in pre-release builds, but code written
  against one will no longer compile: drop `maxFileSizeInBytes` from each `Source` and pass it
  after `sources` instead — omit it to take the 100 MiB default:

  ```ballerina
  // Before
  check new (azureConnection, [{share: "documents", maxFileSizeInBytes: 10485760}]);
  // After
  check new (azureConnection, [{share: "documents"}], 10485760);
  ```

  Configurations that set different limits per source must now use the largest of them (or
  construct one loader per limit)
