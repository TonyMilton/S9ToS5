# S9 to S5 Converter

A macOS app that converts Lumix S9 RW2 raw files for Capture One Pro 23 compatibility.

## The Problem

Capture One Pro 23 doesn't support the Panasonic Lumix S9 camera. However, it does support the Lumix S5, which uses a nearly identical sensor and raw format.

## The Solution

This app modifies the EXIF Model tag in RW2 files from "DC-S9" to "DC-S5", allowing Capture One to import and process the files.

## Safety Features

- Creates a backup before modifying each file
- Validates the file is a legitimate Lumix S9 RW2 before modification
- Verifies the TIFF structure remains intact after modification
- Confirms file size is unchanged (byte-for-byte same size)
- Automatically restores from backup if any validation fails

## Requirements

- macOS 13.0 or later
- Xcode 15+ (to build from source)

## Building

1. Clone the repository
2. Open `S9ToS5.xcodeproj` in Xcode
3. Build and run (⌘R)

Or build from command line:

```bash
xcodebuild -project S9ToS5.xcodeproj -scheme S9ToS5 -configuration Release build
```

The app will be in `~/Library/Developer/Xcode/DerivedData/S9ToS5-*/Build/Products/Release/`

## Usage

1. Launch the app
2. Click "Choose Folder" and select a folder containing your S9 RW2 files
3. Click "Convert Files"
4. Import the converted files into Capture One
