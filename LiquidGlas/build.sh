#!/bin/bash

# LiquidGlas Build Script
# Automated compilation and packaging for iOS Control Center Glass Effect

set -e

echo "=========================================="
echo "  LiquidGlas Tweak Builder"
echo "  Building Control Center Glass Effect..."
echo "=========================================="

cd "$(dirname "$0")"

# Clean previous builds
rm -rf build release-debs

# Create build directories
mkdir -p build release-debs

# Set up Theos environment
export THEOS=1
export ARCHS="arm64"

# Build tweak
echo "Step 1: Compiling LiquidGlas..."
make clean
make package

if [ $? -eq 0 ]; then
    echo ""
    echo "=========================================="
    echo "  ✓ Build Successful!"
    echo ""
    echo "Output location:"
    find release-debs -name "*.deb" | head -1
    
    echo ""
    echo "Package details:"
    if [ -f release-debs/*.deb ]; then
        ls -lh release-debs/*.deb
    fi
else
    echo ""
    echo "✗ Build Failed!"
    exit 1
fi

echo "=========================================="
