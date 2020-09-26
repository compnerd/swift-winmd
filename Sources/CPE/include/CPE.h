
#ifndef CPE_CPE_h
#define CPE_CPE_h

#include <stdint.h>

#define IMAGE_DOS_SIGNATURE 0x5a4d
#define IMAGE_NT_SIGNATURE 0x00004550

#define IMAGE_NT_OPTIONAL_HDR32_MAGIC 0x10b
#define IMAGE_NT_OPTIONAL_HDR64_MAGIC 0x20b

#define IMAGE_NUMBEROF_DIRECTORY_ENTRIES 16
#define IMAGE_SIZEOF_SHORT_NAME 8

typedef struct _IMAGE_DOS_HEADER {
   uint8_t  e_magic;
   uint8_t  e_cblp;
   uint8_t  e_cp;
   uint8_t  e_crlc;
   uint8_t  e_cparhdr;
   uint8_t  e_minalloc;
   uint8_t  e_maxalloc;
   uint8_t  e_ss;
   uint8_t  e_sp;
   uint8_t  e_csum;
   uint8_t  e_ip;
   uint8_t  e_cs;
   uint8_t  e_lfarlc;
   uint8_t  e_ovno;
   uint8_t  e_res[4];
   uint8_t  e_oemid;
   uint8_t  e_oeminfo;
   uint8_t  e_res2[10];
  uint32_t  e_lfanew;
} IMAGE_DOS_HEADER, *PIMAGE_DOS_HEADER;

typedef struct _IMAGE_FILE_HEADER {
  uint16_t  Machine;
  uint16_t  NumberOfSections;
  uint32_t  TimeDateStamp;
  uint32_t  PointerToSymbolTable;
  uint32_t  NumberOfSymbols;
  uint16_t  SizeOfOptionalHeader;
  uint16_t  Characteristics;
} IMAGE_FILE_HEADER, *PIMAGE_FILE_HEADER;

typedef struct _IMAGE_DATA_DIRECTORY {
  uint32_t VirtualAddress;
  uint32_t Size;
} IMAGE_DATA_DIRECTORY, *PIMAGE_DATA_DIRECTORY;

typedef struct _IMAGE_OPTIONAL_HEADER {
  uint16_t             Magic;
   uint8_t             MajorLinkerVersion;
   uint8_t             MinorLinkerVersion;
  uint32_t             SizeOfCode;
  uint32_t             SizeOfInitializedData;
  uint32_t             SizeOfUninitializedData;
  uint32_t             AddressOfEntryPoint;
  uint32_t             BaseOfCode;
  uint32_t             BaseOfData;
  uint32_t             ImageBase;
  uint32_t             SectionAlignment;
  uint32_t             FileAlignment;
  uint16_t             MajorOperatingSystemVersion;
  uint16_t             MinorOperatingSystemVersion;
  uint16_t             MajorImageVersion;
  uint16_t             MinorImageVersion;
  uint16_t             MajorSubsystemVersion;
  uint16_t             MinorSubsystemVersion;
  uint32_t             Win32VersionValue;
  uint32_t             SizeOfImage;
  uint32_t             SizeOfHeaders;
  uint32_t             CheckSum;
  uint16_t             Subsystem;
  uint16_t             DllCharacteristics;
  uint32_t             SizeOfStackReserve;
  uint32_t             SizeOfStackCommit;
  uint32_t             SizeOfHeapReserve;
  uint32_t             SizeOfHeapCommit;
  uint32_t             LoaderFlags;
  uint32_t             NumberOfRvaAndSizes;
  IMAGE_DATA_DIRECTORY DataDirectory[IMAGE_NUMBEROF_DIRECTORY_ENTRIES];
} IMAGE_OPTIONAL_HEADER32, *PIMAGE_OPTIONAL_HEADER32;

typedef struct _IMAGE_NT_HEADERS {
  uint32_t                Signature;
  IMAGE_FILE_HEADER       FileHeader;
  IMAGE_OPTIONAL_HEADER32 OptionalHeader;
} IMAGE_NT_HEADERS32, *PIMAGE_NT_HEADERS32;

typedef struct _IMAGE_OPTIONAL_HEADER64 {
  uint16_t             Magic;
   uint8_t             MajorLinkerVersion;
   uint8_t             MinorLinkerVersion;
  uint32_t             SizeOfCode;
  uint32_t             SizeOfInitializedData;
  uint32_t             SizeOfUninitializedData;
  uint32_t             AddressOfEntryPoint;
  uint32_t             BaseOfCode;
  uint64_t             ImageBase;
  uint32_t             SectionAlignment;
  uint32_t             FileAlignment;
  uint16_t             MajorOperatingSystemVersion;
  uint16_t             MinorOperatingSystemVersion;
  uint16_t             MajorImageVersion;
  uint16_t             MinorImageVersion;
  uint16_t             MajorSubsystemVersion;
  uint16_t             MinorSubsystemVersion;
  uint32_t             Win32VersionValue;
  uint32_t             SizeOfImage;
  uint32_t             SizeOfHeaders;
  uint32_t             CheckSum;
  uint16_t             Subsystem;
  uint16_t             DllCharacteristics;
  uint64_t             SizeOfStackReserve;
  uint64_t             SizeOfStackCommit;
  uint64_t             SizeOfHeapReserve;
  uint64_t             SizeOfHeapCommit;
  uint32_t             LoaderFlags;
  uint32_t             NumberOfRvaAndSizes;
  IMAGE_DATA_DIRECTORY DataDirectory[IMAGE_NUMBEROF_DIRECTORY_ENTRIES];
} IMAGE_OPTIONAL_HEADER64, *PIMAGE_OPTIONAL_HEADER64;

typedef struct _IMAGE_NT_HEADERS64 {
  uint32_t                Signature;
  IMAGE_FILE_HEADER       FileHeader;
  IMAGE_OPTIONAL_HEADER64 OptionalHeader;
} IMAGE_NT_HEADERS64, *PIMAGE_NT_HEADERS64;

typedef struct _IMAGE_SECTION_HEADER {
  uint8_t     Name[IMAGE_SIZEOF_SHORT_NAME];
  union {
    uint32_t  PhysicalAddress;
    uint32_t  VirtualSize;
  } Misc;
  uint32_t    VirtualAddress;
  uint32_t    SizeOfRawData;
  uint32_t    PointerToRawData;
  uint32_t    PointerToRelocations;
  uint32_t    PointerToLinenumbers;
  uint16_t    NumberOfRelocations;
  uint16_t    NumberOfLinenumbers;
  uint32_t    Characteristics;
} IMAGE_SECTION_HEADER, *PIMAGE_SECTION_HEADER;

typedef struct _IMAGE_COR20_HEADER {
    uint32_t                cb;
    uint16_t                MajorRuntimeVersion;
    uint16_t                MinorRuntimeVersion;
    IMAGE_DATA_DIRECTORY    MetaData;
    uint32_t                Flags;
    union {
        uint32_t            EntryPointToken;
        uint32_t            EntryPointRVA;
    } u;
    IMAGE_DATA_DIRECTORY    Resources;
    IMAGE_DATA_DIRECTORY    StrongNameSignature;
    IMAGE_DATA_DIRECTORY    CodeManagerTable;
    IMAGE_DATA_DIRECTORY    VTableFixups;
    IMAGE_DATA_DIRECTORY    ExportAddressTableJumps;
    IMAGE_DATA_DIRECTORY    ManagedNativeHeader;
} IMAGE_COR20_HEADER, *PIMAGE_COR20_HEADER;

#endif
