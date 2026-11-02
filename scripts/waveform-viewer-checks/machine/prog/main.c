/* Machine-state fixture program (our own): exercises register writes, word/half/byte stores and
   loads (signed and unsigned, at every byte offset), .rodata and .data read before any write
   (ELF image), .bss read before any write (zero fill past p_filesz), calls and recursion. */
typedef unsigned int u32;
typedef unsigned short u16;
typedef unsigned char u8;

static const u32 table[16] = { 0x01234567, 0x89abcdef, 0xdeadbeef, 0x00c0ffee, 0x13579bdf, 0x2468ace0,
  0xfedcba98, 0x76543210, 7, 11, 13, 17, 19, 23, 29, 31 };
static const char message[] = "machine state";
volatile u32 data_words[8] = { 5, 3, 8, 1, 9, 2, 7, 4 };
volatile u8 bytes[16];
volatile u16 halves[8];
volatile int bss_words[8];
volatile u32 sink;

static __attribute__((noinline)) u32 fib(u32 n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }

static __attribute__((noinline)) void sort(volatile u32 *a, int n) {
  for (int i = 0; i < n; i++)
    for (int j = 0; j + 1 < n - i; j++)
      if (a[j] > a[j + 1]) { u32 t = a[j]; a[j] = a[j + 1]; a[j + 1] = t; }
}

#ifdef WITH_M
#define MUL(a, b) ((a) * (b))
#else
static __attribute__((noinline)) u32 mul(u32 a, u32 b) { u32 r = 0; while (b) { if (b & 1) r += a; a <<= 1; b >>= 1; } return r; }
#define MUL(a, b) mul((a), (b))
#endif

static __attribute__((noinline)) u32 mix(u32 x, u32 y) {
#ifdef WITH_M
  return x * 2654435761u + y / 3 + (y % 7);
#else
  return (x << 5) - x + (y >> 3) + (y ^ 0x5a5a5a5a);
#endif
}

int main(void) {
  u32 acc = 0;
  for (int i = 0; i < 16; i++) acc = mix(acc, table[i]);
  for (int i = 0; message[i]; i++) bytes[i & 15] = (u8)(message[i] + i);
  for (int i = 0; i < 8; i++) halves[i] = (u16)(table[i] >> (i * 2));
  int s = 0;
  for (int i = 0; i < 16; i++) s += (signed char)bytes[i];
  for (int i = 0; i < 8; i++) s += (short)halves[i];
  for (int i = 0; i < 8; i++) s += bss_words[i];
  sort(data_words, 8);
  for (int i = 0; i < 8; i++) bss_words[i] = (int)MUL(data_words[i], (u32)(i + 1)) - s;
  acc ^= fib(9);
#ifdef WITH_CSR
  u32 old;
  __asm__ volatile("csrrw %0, mscratch, %1" : "=r"(old) : "r"(acc));
  __asm__ volatile("csrr %0, mscratch" : "=r"(old));
  acc += old;
#endif
  sink = acc + (u32)s;
  return 0;
}
