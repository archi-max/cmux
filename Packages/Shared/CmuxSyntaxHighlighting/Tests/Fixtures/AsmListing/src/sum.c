/* cmux asm-listing fixture (written for cmux's tests; public domain / CC0). */
static int table[8] = {1, 2, 3, 4, 5, 6, 7, 8};

int sum(int base)
{
    int total = base;
    for (int i = 0; i < 8; i++)
        total += table[i];
    return total;
}
