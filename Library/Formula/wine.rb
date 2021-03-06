require 'formula'

# NOTE: When updating Wine, please check Wine-Gecko and Wine-Mono for updates too:
# http://wiki.winehq.org/Gecko
# http://wiki.winehq.org/Mono
class Wine < Formula
  homepage 'http://winehq.org/'

  stable do
    url 'http://downloads.sourceforge.net/project/wine/Source/wine-1.6.1.tar.bz2'
    sha256 'd5bc2c088b555caa60a7ba1156e6ed74d791ba3c438129c75ab53805215a384c'

    depends_on 'little-cms'

    resource 'gecko' do
      url 'http://downloads.sourceforge.net/wine/wine_gecko-2.21-x86.msi', :using => :nounzip
      version '2.21'
      sha1 'a514fc4d53783a586c7880a676c415695fe934a3'
    end
  end

  devel do
    url 'http://downloads.sourceforge.net/project/wine/Source/wine-1.7.9.tar.bz2'
    sha256 '79f99ecc24696915439c474c4953bb77652ab53f16b41daa4da270fe43279c5a'
    depends_on 'little-cms2'
  end

  head do
    url 'git://source.winehq.org/git/wine.git'
    depends_on 'little-cms2'
  end

  env :std

  # note that all wine dependencies should declare a --universal option in their formula,
  # otherwise homebrew will not notice that they are not built universal
  require_universal_deps

  # Wine will build both the Mac and the X11 driver by default, and you can switch
  # between them. But if you really want to build without X11, you can.
  depends_on :x11 => :recommended
  depends_on 'freetype' if build.without? 'x11'
  depends_on 'jpeg'
  depends_on 'libgphoto2'
  depends_on 'libicns'
  depends_on 'libtiff'
  depends_on 'sane-backends'
  depends_on 'libgsm' => :optional

  resource 'gecko' do
    url 'http://downloads.sourceforge.net/wine/wine_gecko-2.24-x86.msi', :using => :nounzip
    version '2.24'
    sha1 'b4923c0565e6cbd20075a0d4119ce3b48424f962'
  end

  resource 'mono' do
    url 'http://downloads.sourceforge.net/wine/wine-mono-0.0.8.msi', :using => :nounzip
    sha256 '3dfc23bbc29015e4e538dab8b83cb825d3248a0e5cf3b3318503ee7331115402'
  end

  fails_with :llvm do
    build 2336
    cause 'llvm-gcc does not respect force_align_arg_pointer'
  end

  fails_with :clang do
    build 421
    cause 'error: invalid operand for instruction lretw'
  end

  # There may be flicker in fullscreen mode, but there is no current patch:
  # # http://bugs.winehq.org/show_bug.cgi?id=34166

  # These libraries are not specified as dependencies, or not built as 32-bit:
  # configure: libv4l, gstreamer-0.10, libcapi20, libgsm

  # Wine loads many libraries lazily using dlopen calls, so it needs these paths
  # to be searched by dyld.
  # Including /usr/lib because wine, as of 1.3.15, tries to dlopen
  # libncurses.5.4.dylib, and fails to find it without the fallback path.

  def library_path
    paths = %W[#{HOMEBREW_PREFIX}/lib /usr/lib]
    paths.unshift(MacOS::X11.lib) unless build.without? 'x11'
    paths.join(':')
  end

  def wine_wrapper; <<-EOS.undent
    #!/bin/sh
    DYLD_FALLBACK_LIBRARY_PATH="#{library_path}" "#{bin}/wine.bin" "$@"
    EOS
  end

  def install
    # Build 32-bit; Wine doesn't support 64-bit host builds on OS X.
    build32 = "-arch i386 -m32"

    ENV.append "CFLAGS", build32
    ENV.append "LDFLAGS", build32

    # The clang that comes with Xcode 5 no longer miscompiles wine. Tested with 1.7.3.
    if ENV.compiler == :clang and MacOS.clang_build_version < 500
      opoo <<-EOS.undent
        Clang currently miscompiles some parts of Wine.
        If you have GCC, you can get a more stable build with:
          brew install wine --cc=gcc-4.2 # or 4.7, 4.8, etc.
      EOS
    end

    # Workarounds for XCode not including pkg-config files
    # FIXME we include pkg-config files for libxml2 and libxslt. Is this really necessary?
    ENV.libxml2
    ENV.append "LDFLAGS", "-lxslt"

    # Note: we get freetype from :x11, but if the freetype formula has been installed
    # separately and not built universal, it's going to get picked up and break the build.
    # We cannot use FREETYPE_LIBS because it is inserted after LDFLAGS and thus cannot
    # take precedence over the homebrew freetype.
    ENV.prepend "LDFLAGS", "-L#{MacOS::X11.lib}" unless build.without? 'x11'

    args = ["--prefix=#{prefix}"]
    args << "--disable-win16" if MacOS.version <= :leopard or ENV.compiler == :clang

    # 64-bit builds of mpg123 are incompatible with 32-bit builds of Wine
    args << "--without-mpg123" if Hardware.is_64_bit?

    args << "--without-x" if build.without? 'x11'

    system "./configure", *args

    unless ENV.compiler == :clang or ENV.compiler == :llvm
      # The Mac driver uses blocks and must be compiled with clang even if the rest of
      # Wine is built with gcc. This must be done after configure.
      system 'make', 'dlls/winemac.drv/Makefile'
      inreplace 'dlls/winemac.drv/Makefile', /^CC\s*=\s*[^\s]+/, "CC = clang"
    end

    system "make install"
    (share/'wine/gecko').install resource('gecko')
    (share/'wine/mono').install resource('mono')

    # Use a wrapper script, so rename wine to wine.bin
    # and name our startup script wine
    mv bin/'wine', bin/'wine.bin'
    (bin/'wine').write(wine_wrapper)

    # Don't need Gnome desktop support
    (share/'applications').rmtree
  end

  def caveats
    s = <<-EOS.undent
      You may want to get winetricks:
        brew install winetricks

      The current version of Wine contains a partial implementation of dwrite.dll
      which may cause text rendering issues in applications such as Steam.
      We recommend that you run winecfg, add an override for dwrite in the
      Libraries tab, and edit the override mode to "disable". See:
        http://bugs.winehq.org/show_bug.cgi?id=31374
    EOS

    unless build.without? 'x11'
      s += <<-EOS.undent

        By default Wine uses a native Mac driver. To switch to the X11 driver, use
        regedit to set the "graphics" key under "HKCU\Software\Wine\Drivers" to
        "x11" (or use winetricks).

        For best results with X11, install the latest version of XQuartz:
          http://xquartz.macosforge.org/
      EOS
    end
    return s
  end
end
