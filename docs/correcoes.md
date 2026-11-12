# As três correções — engenharia

Este documento explica o que estava quebrado, como foi isolado e o que cada
patch faz. Tudo foi medido no cliente rodando; nenhum ajuste é "chute".

---

## 1. TLS 16-alinhado (`dlls/ntdll/loader.c`)

### Sintoma

Crash `0xC0000005` intermitente ao entrar no jogo, sempre no mesmo ponto:

```
movaps [esi], xmm0        ; esi = bloco TLS do módulo
```

`movaps` exige 16 bytes de alinhamento. O `esi` vinha de
`TEB->ThreadLocalStoragePointer[i]`, que é o bloco de dados TLS alocado pelo
loader do Wine com `RtlAllocateHeap`.

### Causa

No 32-bit o heap do Wine usa `BLOCK_ALIGN = 2 * sizeof(void*) = 8`. O Windows
garante 16 para esse bloco; o jogo confia nisso e usa SSE. Quando a alocação
caía em endereço 8 (mod 16), o cliente morria — daí a intermitência.

### Correção

Alocar com folga, alinhar e guardar o ponteiro bruto na palavra imediatamente
antes do bloco:

```c
#define TLS_BLOCK_ALIGN 16

static void *tls_block_alloc( SIZE_T size )
{
    void *raw, *ptr;
    if (!(raw = RtlAllocateHeap( GetProcessHeap(), 0,
                                 size + TLS_BLOCK_ALIGN + sizeof(void *) ))) return NULL;
    ptr = (void *)(((ULONG_PTR)raw + sizeof(void *) + TLS_BLOCK_ALIGN - 1) &
                   ~(ULONG_PTR)(TLS_BLOCK_ALIGN - 1));
    ((void **)ptr)[-1] = raw;
    return ptr;
}

static void tls_block_free( void *ptr )
{
    if (!ptr) return;                       /* slots sem TLS são NULL! */
    RtlFreeHeap( GetProcessHeap(), 0, ((void **)ptr)[-1] );
}
```

Os **três** caminhos de liberação (`alloc_tls_slot` ao trocar o bloco antigo, o
erro de `alloc_thread_tls` e a saída de thread) passaram a usar
`tls_block_free()`.

> A armadilha: no `for (i = 0; i < tls_module_count; i++) RtlFreeHeap(..., pointers[i])`
> os slots sem TLS valem `NULL`; ler `((void**)NULL)[-1]` derruba qualquer
> processo. Um guarda de `NULL` resolve.

### Como validar

```bash
# lê fs:0x2c e imprime o alinhamento de cada bloco
wine tlstest.exe       # esperado: "desalinhados=0"
```

O `tlstest2` (50 DLLs com TLS + 8 threads + unload) força o crescimento de
`tls_dirs` e exercita os três frees.

---

## 2. `ScriptTextOut` com cache vazio (`dlls/gdi32/uniscribe/usp10.c`)

### Sintoma

Todo texto dinâmico (servidores, canais, nick, Gold/Exp) aparecia com letras
trocadas — `& DCOO0 D#KP DNQJ` — enquanto texto "assado" em textura aparecia
certo.

### Diagnóstico

Instrumentando `ScriptShape` e `ExtTextOutW` (`WINEDEBUG=+uniscribe,+bidi`):

- `ScriptShape` devolvia exatamente os mesmos índices de glifo do
  `GetGlyphIndicesW` (nada errado no shaping).
- As 575 chamadas de texto do cliente iam para **um único DIB 256×256**, uma
  letra por vez, todas com `glyph_idx=0` — ou seja, o GDI estava recebendo
  **caracteres**, não índices.
- Um backtrace mostrou que o desenho vinha do próprio `ScriptTextOut` do Wine.

E o `ScriptTextOut` imprimia:

```
ScriptTextOut aNoGlyph=0 psc=00000000 sfnt=00000000 glyph0=82 cGlyphs=1
                           ^^^^^^^^^^^^^ *psc == NULL (566/566 chamadas)
```

### Causa

```c
if (!psa->fNoGlyphIndex && *psc && ((ScriptCache *)*psc)->sfnt)
    fuOptions |= ETO_GLYPH_INDEX;   /* só usa glifos se o cache já existir */
```

O cliente passa um `SCRIPT_CACHE` vazio (ponteiro para `NULL`), que é uso normal
na API. Com `*psc == NULL` a condição falha, o Wine não liga `ETO_GLYPH_INDEX` e
o `ExtTextOutW` interpreta os **índices de glifo como códigos de caractere**,
aplicando o cmap uma segunda vez. Cada célula do atlas recebia o glifo de outra
letra.

### Correção

```c
if (!psa->fNoGlyphIndex && !*psc)
    init_script_cache(hdc, psc);
if (!psa->fNoGlyphIndex && *psc && ((ScriptCache *)*psc)->sfnt)
    fuOptions |= ETO_GLYPH_INDEX;
```

`init_script_cache()` é barata (lookup de `LOGFONT` numa lista global com
refcount), então as 566 chamadas de montagem do atlas não pesam.

### Resultado

| Antes | Depois |
|---|---|
| `& DCOO0 D#KP DNQJ` | `Canal Matchmaking` |
| `6HUm LW` | `Server List` |
| `OODU$H0…9E#FR` | `001 Servidor Publico` |
| `Lv.44 xLOOR` | `theLuziano · Gold 100.981 · Exp 1452/2000` |

---

## 3. DXVK com command list nulo (`d3d11.dll`)

### Sintoma

Crash `0xC0000005` em `d3d11.dll +0x9E4B`, ~1 a 2 minutos após abrir, sempre no
mesmo lugar:

```
0x9E4B:  mov eax,[ecx+0x2c]      ; ecx = 0
```

### Diagnóstico

`ntdll` instrumentada para imprimir backtrace em `EXCEPTION_ACCESS_VIOLATION`:

```
dispatch_exception code=c0000005 addr=...9E4B
 info[1]=0000002c      <- leitura de 0x2c (this nulo)
 ecx=00000000
 backtrace: d3d11+0x2CAE6 <- cliente
```

O cliente chama `ID3D11DeviceContext::ExecuteCommandList(NULL, FALSE)` (vtable
`+0xE8`) no caminho de montagem de command lists do renderizador. O DXVK — 1.10.3,
2.0 e o master — **não valida** o ponteiro:

```cpp
auto commandList = static_cast<D3D11CommandList*>(pCommandList);
uint64_t csSeqNum = commandList->EmitToCsThread(&m_csThread);  // -> [ecx+0x2c]
```

### Correção

Patch binário de 16 bytes: intercepta a chamada e devolve 0 quando o ponteiro é
nulo; com ponteiro válido, salta para a função original.

```
call site  RVA 0x2CAE1:  e8 5a d3 fd ff  ->  e8 fb 7a 22 00   (vai para a cave)
cave       RVA 0x2545E1:  85 c9        test ecx,ecx
                          74 05        jz .null
                          e9 56 58 db ff   jmp 0x9E40        (original)
                   .null: 31 c0        xor eax,eax
                          31 d2        xor edx,edx
                          c2 04 00     ret 4                 (__thiscall)
```

A cave fica no preenchimento do fim da última página do `.text` (zeros, dentro
do `VirtualSize`, portanto mapeado e executável). O `ret 4` respeita a convenção
da função original e o retorno `0/0` é exatamente o que o chamador usa no
cálculo de `m_csSeqNum`.

Script idempotente (guarda `d3d11.dll.orig` e sabe reverter):

```bash
python3 payload/patches/patch-dxvk-null-cmdlist.py \
        ~/.wine-pb/drive_c/windows/syswow64/d3d11.dll
```

### Resultado

Antes: 3 de 4 execuções caiam nesse endereço. Depois: 3/3 estáveis, e uma
partida completa foi jogada.

---

## A ponte HTTP→HTTPS (rede)

O launcher faz `GET /gamepatch/... HTTP/1.1` com `Host: patch-br.zepetto.com:443`
— HTTP puro na porta TLS. O WinHttp do Windows promove para TLS; o do Wine não.

Solução instalada:

1. `iptables -t nat` redireciona **só** o 443 dos IPs do patch server para
   `127.0.0.1:8443` (com `RETURN` para o uid 0, senão a ponte entra em loop);
2. `pb-bridge.py` aceita HTTP, resolve o `Host`, abre TLS de verdade e devolve a
   resposta; se o primeiro byte for `0x16` (ClientHello TLS), faz túnel bruto
   para o destino original (`SO_ORIGINAL_DST`).

---

## Reproduzindo os patches do Wine

```bash
./scripts/construir-wine.sh      # baixa o fonte, aplica payload/patches/0*.patch
```

Os patches são `diff -u` contra o Wine 9.0 original (`patch -p1` a partir da
raiz do fonte).
