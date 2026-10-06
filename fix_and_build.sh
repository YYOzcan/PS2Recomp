#!/usr/bin/env bash
# fix_and_build.sh — Gradius III/IV static recomp derleme onarım + derleme betiği
# Tek tuşla: forward-decl üret -> senkronize et -> CMake yamala -> unity build -> doğrula.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="/home/yigit/gradius_recomp/output"
RUNTIME_DIR="${REPO_ROOT}/ps2xRuntime"
INCLUDE_DIR="${RUNTIME_DIR}/include"
RUNNER_DIR="${RUNTIME_DIR}/src/runner"
CMAKE_FILE="${RUNTIME_DIR}/CMakeLists.txt"
BUILD_DIR="${REPO_ROOT}/build"
ALL_DECL_NAME="ps2_all_declarations.h"
ALL_DECL_OUTPUT="${OUTPUT_DIR}/${ALL_DECL_NAME}"
FORCED_INCLUDE="${OUTPUT_DIR}/${ALL_DECL_NAME}"

log() { printf '[fix_and_build] %s\n' "$*"; }
die() { printf '[fix_and_build][HATA] %s\n' "$*" >&2; exit 1; }

[ -d "${OUTPUT_DIR}" ] || die "OUTPUT_DIR bulunamadı: ${OUTPUT_DIR}"
[ -f "${CMAKE_FILE}" ] || die "CMakeLists.txt bulunamadı: ${CMAKE_FILE}"
command -v cmake >/dev/null 2>&1 || die "cmake bulunamadı"
command -v ninja >/dev/null 2>&1 || log "UYARI: ninja bulunamadı, cmake varsayılan generator kullanılacak"

# ---------------------------------------------------------------- 1. Forward declarations
log "1/4: sub_*/entry_* sembolleri taranıyor: ${OUTPUT_DIR}"
TMP_SUB="$(mktemp)"
TMP_ENTRY="$(mktemp)"
TMP_BASE="$(mktemp)"
TMP_ALL="$(mktemp)"
trap 'rm -f "${TMP_SUB}" "${TMP_ENTRY}" "${TMP_BASE}" "${TMP_ALL}"' EXIT

# Çağrılan + tanımlanan tüm sub_ sembolleri (tam ad: sub_<hex>_0x<hex>).
# Not: 'sub_[0-9A-Fa-f]+' kalıbı tek başına sonek (_0x...) kısmını keser ve
# '// Function: sub_XXXX' yorumlarındaki çıplak adları da yakalar; bu yüzden
# bildirimler için sonekli tam ad kalıbı kullanılır (sort -u ile tekilleştirilir).
grep -rhoE 'sub_[0-9A-Fa-f]+_0x[0-9A-Fa-f]+' "${OUTPUT_DIR}" --include='*.cpp' > "${TMP_SUB}" || true
# Dinamik atlama fallback etiketleri.
grep -rhoE 'entry_[0-9A-Fa-f]+_[0-9A-Fa-f]+' "${OUTPUT_DIR}" --include='*.cpp' > "${TMP_ENTRY}" || true
# Dosya adlarından tanımlar (grep'in kaçırabileceğine karşı emniyet).
for f in "${OUTPUT_DIR}"/sub_*.cpp "${OUTPUT_DIR}"/entry_*.cpp; do
  [ -e "$f" ] || continue
  basename "$f" .cpp >> "${TMP_BASE}"
done || true

cat "${TMP_SUB}" "${TMP_ENTRY}" "${TMP_BASE}" | sort -u | grep -v '^$' > "${TMP_ALL}" || true
SYM_COUNT="$(wc -l < "${TMP_ALL}" | tr -d ' ')"
log "Bulunan tekil sembol sayısı: ${SYM_COUNT}"
[ "${SYM_COUNT}" -gt 0 ] || die "Hiç sembol bulunamadı, OUTPUT_DIR boş mu?"

{
  echo "#pragma once"
  echo ""
  echo "// OTOMATIK URETILDI — fix_and_build.sh"
  echo "// Kaynak: ${OUTPUT_DIR}/*.cpp (sub_* + entry_* taraması, sort -u)"
  echo "// Sembol sayisi: ${SYM_COUNT}"
  echo "#include <cstdint>"
  echo ""
  echo "struct R5900Context;"
  echo "class PS2Runtime;"
  echo ""
  while IFS= read -r sym; do
    printf 'void %s(uint8_t* rdram, R5900Context* ctx, PS2Runtime* runtime);\n' "${sym}"
  done < "${TMP_ALL}"
} > "${ALL_DECL_OUTPUT}"
log "Üretildi: ${ALL_DECL_OUTPUT} (${SYM_COUNT} bildirim)"

# ---------------------------------------------------------------- 2. Dosya senkronizasyonu
log "2/4: header + register_functions senkronize ediliyor"
cp -f "${ALL_DECL_OUTPUT}" "${INCLUDE_DIR}/${ALL_DECL_NAME}"
for h in ps2_recompiled_functions.h ps2_recompiled_stubs.h; do
  if [ -f "${OUTPUT_DIR}/${h}" ]; then
    cp -f "${OUTPUT_DIR}/${h}" "${INCLUDE_DIR}/${h}"
    log "Kopyalandı: ${h} -> include/"
  else
    log "UYARI: ${OUTPUT_DIR}/${h} yok, atlandı"
  fi
done
cp -f "${OUTPUT_DIR}/register_functions.cpp" "${RUNNER_DIR}/register_functions.cpp"
log "Kopyalandı: register_functions.cpp -> src/runner/"

# Stale temizliği (kritik): src/runner içindeki eski recomp çıktıları
# (output ile çakışmayan 6000+ sub_*.cpp + entry_*.cpp) hem eksik-bildirim
# hatası hem de 156 dosyada çoklu-tanım hatası üretir. output glob'u zaten
# tüm güncel kaynakları derlemeye kattığı için bunlar güvenle silinir.
shopt -s nullglob
_stale_sub=( "${RUNNER_DIR}"/sub_*.cpp )
_stale_entry=( "${RUNNER_DIR}"/entry_*.cpp )
shopt -u nullglob
STALE_SUB_COUNT="${#_stale_sub[@]}"
STALE_ENTRY_COUNT="${#_stale_entry[@]}"
if [ "${STALE_SUB_COUNT}" -gt 0 ] || [ "${STALE_ENTRY_COUNT}" -gt 0 ]; then
  log "Stale temizliği: ${STALE_SUB_COUNT} sub_*.cpp + ${STALE_ENTRY_COUNT} entry_*.cpp siliniyor (src/runner)"
  rm -f "${RUNNER_DIR}"/sub_*.cpp "${RUNNER_DIR}"/entry_*.cpp
else
  log "Stale dosya yok, temizlik atlandı"
fi

# ---------------------------------------------------------------- 3. CMake yapılandırması
log "3/4: CMakeLists.txt yamalanıyor: ${CMAKE_FILE}"
BACKUP="${CMAKE_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
cp -f "${CMAKE_FILE}" "${BACKUP}"
log "Yedek alındı: ${BACKUP}"

python3 - "${CMAKE_FILE}" "${FORCED_INCLUDE}" <<'PYEOF'
import sys, re
cmake_path, forced = sys.argv[1], sys.argv[2]
src = open(cmake_path, encoding='utf-8').read()

# 3a. RUNNER_SRC_FILES output glob'unu garanti et (idempotent).
if '/home/yigit/gradius_recomp/output/*.cpp' not in src:
    src = src.replace(
        '"${CMAKE_CURRENT_SOURCE_DIR}/src/runner/*.cpp"',
        '"${CMAKE_CURRENT_SOURCE_DIR}/src/runner/*.cpp"\n    "/home/yigit/gradius_recomp/output/*.cpp"',
        1)
    print('[cmake] RUNNER_SRC_FILES output glob eklendi')
else:
    print('[cmake] RUNNER_SRC_FILES output glob zaten mevcut')

# 3a2. Unity redefinition önleme: register_functions.cpp hem src/runner
# kopyasında hem output aslnda var (içerik aynı). Unity build ikisini aynı
# batch'e katıp 'redefinition' hatası veriyor. src/runner kopyası senkron
# yedeği olarak kalır, derlemeye output aslı girer.
dedupe_line = 'list(REMOVE_ITEM RUNNER_SRC_FILES "${CMAKE_CURRENT_SOURCE_DIR}/src/runner/register_functions.cpp")'
if dedupe_line not in src:
    glob_anchor = '"/home/yigit/gradius_recomp/output/*.cpp"\n)'
    if glob_anchor in src:
        src = src.replace(glob_anchor,
            glob_anchor + '\n\n# Unity redefinition önleme: output aslı kanonik, src/runner kopyası yedek\n' + dedupe_line,
            1)
        print('[cmake] register_functions.cpp dedupe eklendi (src/runner hariç)')
    else:
        print('[cmake] UYARI: GLOB bloğu bulunamadı, dedupe atlandı')
else:
    print('[cmake] register_functions.cpp dedupe zaten mevcut')

# 3b. Bozuk add_executable bloğunu onar:
#     add_executable(ps2EntryRunner
#     target_compile_options(... -include ...)   <- hedef içinde geçersiz satır
#         ${RUNNER_SRC_FILES}
#     )
broken = '''    add_executable(ps2EntryRunner
    target_compile_options(ps2EntryRunner PRIVATE -include "/home/yigit/gradius_recomp/output/ps2_recompiled_functions.h")
        ${RUNNER_SRC_FILES}
    )'''
fixed = '''    add_executable(ps2EntryRunner
        ${RUNNER_SRC_FILES}
    )'''
if broken in src:
    src = src.replace(broken, fixed, 1)
    print('[cmake] bozuk add_executable bloğu onarıldı')

# 3c. Zorunlu -include bayrağını ayrı ve idempotent komut olarak ekle.
forced_line = f'target_compile_options(ps2EntryRunner PRIVATE -include "{forced}")'
if forced_line not in src:
    anchor = 'endif()\n\nif(PS2X_ENABLE_RUNNER_UNITY_BUILD)'
    addition = f'endif()\n\n{forced_line}\n\nif(PS2X_ENABLE_RUNNER_UNITY_BUILD)'
    if anchor in src:
        src = src.replace(anchor, addition, 1)
        print(f'[cmake] zorunlu -include eklendi: {forced}')
    else:
        # Anchor bulunamazsa runner unity bloğundan önce kaba ekleme.
        anchor2 = 'if(PS2X_ENABLE_RUNNER_UNITY_BUILD)'
        src = src.replace(anchor2, forced_line + '\n\n' + anchor2, 1)
        print(f'[cmake] zorunlu -include eklendi (fallback): {forced}')
else:
    print('[cmake] zorunlu -include zaten mevcut')

# 3d. Dev register_functions.cpp'de donmayı önlemek için runner LTO'sunu kapat.
#     Aktif satırı yorum satırına çevir (zaten yorumluysa dokunma).
src2, n = re.subn(r'(?m)^(?P<ind>[ \t]*)EnableFastReleaseMode\(ps2EntryRunner\)',
                  r'\g<ind># EnableFastReleaseMode(ps2EntryRunner) - Disabled LTO on runner to prevent compiler hang on huge register_functions',
                  src)
if n:
    src = src2
    print('[cmake] EnableFastReleaseMode(ps2EntryRunner) devre dışı bırakıldı')
else:
    print('[cmake] runner LTO ayarı zaten devre dışı')

open(cmake_path, 'w', encoding='utf-8').write(src)
PYEOF

log "CMake yaması tamam"

# ---------------------------------------------------------------- 4. Kontrollü ve sessiz derleme
log "4/4: Unity build ile yapılandırılıyor (batch=32)"
cmake -S "${REPO_ROOT}" -B "${BUILD_DIR}" \
  -DPS2X_ENABLE_RUNNER_UNITY_BUILD=ON \
  -DPS2X_RUNNER_UNITY_BUILD_BATCH_SIZE=32

log "Derleme başlıyor (nice -n 19, -j3): ps2EntryRunner"
nice -n 19 cmake --build "${BUILD_DIR}" --target ps2EntryRunner -j3

# Doğrulama
BIN_CANDIDATES=(
  "${BUILD_DIR}/ps2xRuntime/ps2EntryRunner"
  "${BUILD_DIR}/ps2EntryRunner"
)
FOUND_BIN=""
for b in "${BIN_CANDIDATES[@]}"; do
  if [ -x "$b" ] && [ -f "$b" ]; then FOUND_BIN="$b"; break; fi
done
if [ -z "${FOUND_BIN}" ]; then
  FOUND_BIN="$(find "${BUILD_DIR}" -maxdepth 4 -type f -name 'ps2EntryRunner' -executable 2>/dev/null | head -n 1 || true)"
fi
[ -n "${FOUND_BIN}" ] || die "ps2EntryRunner ikilisi bulunamadı"
[ -x "${FOUND_BIN}" ] || die "ps2EntryRunner çalıştırılabilir değil: ${FOUND_BIN}"
ls -lh "${FOUND_BIN}"
log "BAŞARILI: ${FOUND_BIN} hazır ve çalıştırılabilir"
