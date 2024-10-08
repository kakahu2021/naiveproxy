// Copyright 2011 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "base/native_library.h"

#include <dlfcn.h>
#include <mach-o/getsect.h>

#include <string_view>

#include "base/apple/scoped_cftyperef.h"
#include "base/files/file_path.h"
#include "base/files/file_util.h"
#include "base/logging.h"
#include "base/strings/strcat.h"
#include "base/strings/string_util.h"
#include "base/strings/sys_string_conversions.h"
#include "base/strings/utf_string_conversions.h"
#include "base/threading/thread_restrictions.h"

namespace base {

static NativeLibraryObjCStatus GetObjCStatusForImage(
    const void* function_pointer) {
  Dl_info info;
  if (!dladdr(function_pointer, &info))
    return OBJC_UNKNOWN;

  // See if the image contains an "ObjC image info" segment. This method
  // of testing is used in _CFBundleGrokObjcImageInfoFromFile in
  // CF-1153.18/CFBundle_Grok.c, around line 349.
  //
  // In 64-bit images, ObjC can be recognized in __DATA,__objc_imageinfo.
  const auto* header =
      reinterpret_cast<const struct mach_header_64*>(info.dli_fbase);
  unsigned long size = 0;
  getsectiondata(header, SEG_DATA, "__objc_imageinfo", &size);
  if (size > 0) {
    return OBJC_PRESENT;
  }
  // ....except when "SharedRegionEncodingV2" is on, it's in
  // __DATA_CONST,__objc_image_info (see https://crbug.com/1220459#c16)
  getsectiondata(header, "__DATA_CONST", "__objc_imageinfo", &size);
  return size > 0 ? OBJC_PRESENT : OBJC_NOT_PRESENT;
}

std::string NativeLibraryLoadError::ToString() const {
  return message;
}

NativeLibrary LoadNativeLibraryWithOptions(const FilePath& library_path,
                                           const NativeLibraryOptions& options,
                                           NativeLibraryLoadError* error) {
  // dlopen() etc. open the file off disk.
  if (library_path.Extension() == "dylib" || !DirectoryExists(library_path)) {
    void* dylib = dlopen(library_path.value().c_str(), RTLD_LAZY);
    if (!dylib) {
      if (error)
        error->message = dlerror();
      return nullptr;
    }
    NativeLibrary native_lib = new NativeLibraryStruct();
    native_lib->type = DYNAMIC_LIB;
    native_lib->dylib = dylib;
    native_lib->objc_status = OBJC_UNKNOWN;
    return native_lib;
  }
  apple::ScopedCFTypeRef<CFURLRef> url(CFURLCreateFromFileSystemRepresentation(
      kCFAllocatorDefault, (const UInt8*)library_path.value().c_str(),
      checked_cast<CFIndex>(library_path.value().length()), true));
  if (!url)
    return nullptr;
  CFBundleRef bundle = CFBundleCreate(kCFAllocatorDefault, url.get());
  if (!bundle)
    return nullptr;

  NativeLibrary native_lib = new NativeLibraryStruct();
  native_lib->type = BUNDLE;
  native_lib->bundle = bundle;
  native_lib->objc_status = OBJC_UNKNOWN;
  return native_lib;
}

void UnloadNativeLibrary(NativeLibrary library) {
  if (library->objc_status == OBJC_NOT_PRESENT) {
    if (library->type == BUNDLE) {
      CFRelease(library->bundle);
    } else {
      dlclose(library->dylib);
    }
  } else {
    VLOG(2) << "Not unloading NativeLibrary because it may contain an ObjC "
               "segment. library->objc_status = " << library->objc_status;
    // Deliberately do not CFRelease the bundle or dlclose the dylib because
    // doing so can corrupt the ObjC runtime method caches. See
    // http://crbug.com/172319 for details.
  }
  delete library;
}

void* GetFunctionPointerFromNativeLibrary(NativeLibrary library,
                                          const char* name) {
  void* function_pointer = nullptr;

  // Get the function pointer using the right API for the type.
  if (library->type == BUNDLE) {
    apple::ScopedCFTypeRef<CFStringRef> symbol_name =
        SysUTF8ToCFStringRef(name);
    function_pointer =
        CFBundleGetFunctionPointerForName(library->bundle, symbol_name.get());
  } else {
    function_pointer = dlsym(library->dylib, name);
  }

  // If this library hasn't been tested for having ObjC, use the function
  // pointer to look up the section information for the library.
  if (function_pointer && library->objc_status == OBJC_UNKNOWN)
    library->objc_status = GetObjCStatusForImage(function_pointer);

  return function_pointer;
}

std::string GetNativeLibraryName(std::string_view name) {
  DCHECK(IsStringASCII(name));
  return StrCat({"lib", name, ".dylib"});
}

std::string GetLoadableModuleName(std::string_view name) {
  DCHECK(IsStringASCII(name));
  return StrCat({name, ".so"});
}

}  // namespace base
