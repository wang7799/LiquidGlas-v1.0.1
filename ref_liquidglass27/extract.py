import re, os
d = r'D:\AI编辑文件储存放\存放\ref_liquidglass27\data\Library\MobileSubstrate\DynamicLibraries'
for fn in ['LiquidGlass27.dylib','BGRenderServer.dylib','BGWidgetRenderer.dylib']:
    data = open(os.path.join(d,fn),'rb').read()
    strs = set(re.findall(rb'[ -~]{5,}', data))
    kw = [b'Metal',b'MTL',b'metallib',b'shader',b'Shader',b'backdrop',b'Backdrop',
          b'CAFilter',b'gaussian',b'refract',b'displace',b'CGS',b'backboard',
          b'MTMaterial',b'Glass',b'glass',b'Group',b'group',b'CAOrder',b'CATransaction',
          b'IOSurface',b'CAMetalLayer',b'newLibrary',b'device']
    out=[]
    for s in strs:
        for k in kw:
            if k in s:
                out.append(s.decode('ascii','replace')); break
    print('==== '+fn+' ====')
    for s in sorted(set(out))[:70]:
        print(s)
    print()
