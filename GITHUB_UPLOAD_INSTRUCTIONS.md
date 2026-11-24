# GitHub Upload & Build Instructions

## 📦 Step 1: Download Optimized Files

所有优化文件已准备完成：

```
存放/LiquidGlas/ (包含以下优化文件)
├── LiquidGlas.m              ✅ 已优化
├── BGRenderServer.m          ✅ 已优化
├── LGPercentageDisplay.m     ✅ 已优化
└── [其他配置文件...]         ✅ 保留
```

---

## 🚀 Step 2: Push to GitHub (Option 1 - gh CLI)

### A. Configure Authentication

```bash
# 首次使用需要登录
gh auth login

# 或配置 token
gh auth setup-git
```

### B. Create Release Branch

```bash
cd "存放/LiquidGlas"

# 创建性能优化分支
git checkout -b performance-optimized

# 提交所有修改
git add .
git commit -m "perf: Optimize GPU/CPU usage for reduced heat and battery consumption

- BGRenderServer.m: Reduced shadow opacity, removed animation loops
- LGPercentageDisplay.m: Discovery interval doubled (1s→2s), scan budget halved
- LiquidGlas.m: Simplified shader, reduced blur amount
- Expected: 30-40% less heat, 25-35% battery saving

Optimized version v1.0-performance"

# Push to branch
git push -u origin performance-optimized
```

### C. Create Release

```bash
# Create release tag
gh release create v1.0-performance --title "v1.0 Performance Optimized" --notes "Performance optimized version for reduced heat and battery consumption"

# Upload .deb (after building)
gh release upload v1.0-performance LiquidGlas_v1.0_performance-optimized_iphoneos-arm64e-roothide.deb
```

---

## 🖥️ Step 3: Build on macOS (Required)

### Prerequisites

```bash
# Install Theos (on macOS only)
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
git clone https://github.com/theos/theos.git
cd theos && make
cd ..

# Add to PATH
export PATH="/path/to/theos/bin:$PATH"
```

### Build Optimized Version

```bash
cd "存放/LiquidGlas"

# Clean and build roothide version
make clean package THEOS_PACKAGE_SCHEME=rootless FINALPACKAGE=1

# Build rootless version (if needed)
make clean package THEOS_PACKAGE_SCHEME=rootless FINALPACKAGE=1 ARCHS=arm64
```

Output will be in `release-debs/` directory.

---

## 📤 Step 4: Upload to Releases

### Manual Upload Option

如果你没有 gh CLI，可以：

1. **生成 .deb** (在 macOS 上完成)
2. **压缩优化文件**:
   ```bash
   # Create optimized source zip
   cd "存放/LiquidGlas"
   tar -czf LiquidGlas-performance-optimized.tar.gz \
       --exclude='release-debs' \
       --exclude='.git' \
       --exclude='*.md'  # Exclude docs for smaller size
   
   # Or create zip
   zip -r -x "*.DS_Store" -x "release-debs/*" LiquidGlas-performance-optimized.zip .
   ```

3. **Upload to GitHub Releases**:
   ```bash
   gh release upload v1.0-performance \
       --clobber \
       LiquidGlas_v1.0_performance-optimized_iphoneos-arm64e-roothide.deb \
       LiquidGlas-performance-optimized.zip
   ```

---

## 📊 Release Assets Structure

建议的 Release 资产：

| Asset Name | Type | Size | Purpose |
|------------|------|------|---------|
| `LiquidGlas_v1.0_performance-optimized_iphoneos-arm64e-roothide.deb` | .deb | ~380KB | Primary install (rootless) |
| `LiquidGlas_v1.0_performance-optimized.zip` | .zip | ~50KB | Source code backup |
| `OPTIMIZATION_SUMMARY.md` | .md | 2KB | Performance report |

---

## 🏷️ Tag Naming Convention

建议的标签命名：
```
v1.0           - Original version (keep)
v1.0-optimized - Performance optimized (new)
v1.0-performance - Alternative name (new)
perf/v1.0      - Branch prefix alternative
```

---

## 🔍 Verify After Upload

### Check Release Assets

```bash
gh api /repos/wang7799/LiquidGlas-v1.0.1/releases/tags/v1.0-optimized
```

### View on GitHub

访问：https://github.com/wang7799/LiquidGlas-v1.0.1/releases/tag/v1.0-optimized

---

## ⚠️ Important Notes

### Before Uploading

1. ✅ Verify all optimized files are present
2. ✅ Test build completes successfully on macOS
3. ✅ Check .deb integrity (SHA256)
4. ✅ Update README.md with performance info

### After Uploading

1. Create a new issue template for bug reports
2. Add changelog entry in releases page
3. Pin the new release if it's the latest
4. Consider deprecating old v1.0.x versions

---

## 🐛 Troubleshooting

### Build Fails

```bash
# Check Theos version
theos --version

# Clean all artifacts
make clean package THEOS_PACKAGE_SCHEME=rootless FINALPACKAGE=1
```

### Push Denied

```bash
# Re-authenticate
gh auth logout
gh auth login -with-token
```

### Missing Frameworks

```bash
# Install Xcode command line tools
xcode-select --install
```

---

*Last Updated: 2024-11-24*  
*Optimized Version: v1.0-performance-optimized*
