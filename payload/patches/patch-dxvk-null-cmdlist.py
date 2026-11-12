#!/usr/bin/env python3
"""patch-dxvk-null-cmdlist.py — torna ExecuteCommandList(NULL) um no-op no DXVK.

O cliente Point Blank, na inicialização do renderizador (i3RenderAttrListAttr
::ApplyForDX11 -> i3CommandListAttr), chama ID3D11DeviceContext::
ExecuteCommandList(ptr_nulo, FALSE).  O DXVK 1.10.3 nao valida o ponteiro e cai
em `mov eax,[ecx+0x2c]` com ecx=0 (crash 0xC0000005 em d3d11.dll+0x9E4B).

Este patch intercepta a chamada e retorna 0 quando o ponteiro e nulo; com
ponteiro valido, salta para a funcao original (sem custo).

Uso:
    ./patch-dxvk-null-cmdlist.py <caminho do d3d11.dll> [--reverter]
"""
import struct, sys, shutil, os

SITE_RVA   = 0x2CAE1     # call <D3D11CommandList::EmitToCsThread(?)> no ExecuteCommandList imediato
CAVE_RVA   = 0x2545E1    # preenchimento no fim da ultima pagina do .text
TARGET_RVA = 0x9E40      # funcao original chamada
CALLEE_RET = 4           # ret 4 (__thiscall: limpa o ponteiro empilhado)

def check(cond, msg):
    if not cond:
        print("ERRO:", msg); sys.exit(1)

def main():
    path = sys.argv[1]
    revert = '--reverter' in sys.argv
    backup = path + '.orig'

    if revert:
        check(os.path.exists(backup), f"backup {backup} nao encontrado")
        shutil.copy2(backup, path)
        print("revertido:", path)
        return

    if not os.path.exists(backup):
        shutil.copy2(path, backup)
        print("backup criado:", backup)

    data = bytearray(open(path, 'rb').read())
    pe = struct.unpack_from('<I', data, 0x3c)[0]
    base = struct.unpack_from('<I', data, pe + 0x18 + 0x1c)[0]
    nsec = struct.unpack_from('<H', data, pe + 6)[0]
    sopt = pe + 0x18 + struct.unpack_from('<H', data, pe + 0x14)[0]
    secs = {}
    for i in range(nsec):
        off = sopt + i * 40
        name = data[off:off+8].rstrip(b'\0').decode()
        vs, va, rs, ra = struct.unpack_from('<IIII', data, off + 8)
        secs[name] = (va, vs, ra, rs)
    check(secs['.text'][0] == secs['.text'][2], "file offset != RVA no .text")

    # confere o estado atual do call site
    cur = bytes(data[SITE_RVA:SITE_RVA+5])
    if cur[0] == 0xe8 and cur != b'\xe8\x5a\xd3\xfd\xff':
        print("call site ja modificado (patch aplicado?)")
    check(cur[0] == 0xe8, "esperava um CALL no call site")

    # cave: 16 bytes
    cave_va = base + CAVE_RVA
    jmp_rel = (base + TARGET_RVA) - (cave_va + 9)
    cave = (b'\x85\xc9'                            # test ecx,ecx
            + b'\x74\x05'                          # jz .null
            + b'\xe9' + struct.pack('<i', jmp_rel)  # jmp funcao original
            + b'\x31\xc0'                          # xor eax,eax
            + b'\x31\xd2'                          # xor edx,edx
            + b'\xc2' + struct.pack('<H', CALLEE_RET))  # ret 4

    # call site -> cave
    new_rel = CAVE_RVA - (SITE_RVA + 5)
    new_call = b'\xe8' + struct.pack('<i', new_rel)

    data[SITE_RVA:SITE_RVA+5] = new_call
    data[CAVE_RVA:CAVE_RVA+len(cave)] = cave
    open(path, 'wb').write(data)

    print(f"patch aplicado em {path}")
    print(f"  call site RVA {SITE_RVA:#x} -> cave RVA {CAVE_RVA:#x}")
    print(f"  cave: {cave.hex()}")
    print(f"  jmp de volta para RVA {TARGET_RVA:#x} (rel={jmp_rel})")

if __name__ == '__main__':
    main()
