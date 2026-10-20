// LN3Couch: второй мир (ореол куклы) в разделённом экране.
//
// Игра вклеивает второй мир в половину экрана функцией своего обработчика
// кадра (по одному на каждую съёмку второго мира, TwoWorldsCaptureComponent),
// и верно — только в половину, что лежит в начале кадра (слева/сверху): её
// шейдер берёт глубину и прочее без сдвига половины. В другой половине
// получался кусок чужой картинки.
//
// Мод ставит держащего куклу первым (он рисуется слева/сверху) и метит
// основную съёмку (SphereMarginConstant):
//   0.25   — вклеивать только в первую половину, места вывода не менять;
//   0.5625 — то же, и поменять места вывода половин слева/справа;
//   0.625  — то же, и поменять места вывода сверху/снизу.
// Так ореол рисуется там, где игра умеет, а на экран каждая половина
// выводится на свою сторону. Без метки всё как в игре.
//
// Загружается из Lua: package.loadlib(путь, "*").
#include <windows.h>
#include <stdio.h>
#include <string.h>

// пятый параметр (на стеке) функция тоже читает — передаём как есть
typedef void (*CompositeFn)(void *ext, void *graph, void *view, void *inputs, void *out);
typedef void *(*WeakGetFn)(void *weak);

static CompositeFn g_orig;
static WeakGetFn g_weakGet;
static char g_logPath[MAX_PATH], g_okPath[MAX_PATH];

static void logmsg(const char *fmt, ...) {
    FILE *f = fopen(g_logPath, "a");
    if (!f) return;
    SYSTEMTIME st; GetLocalTime(&st);
    fprintf(f, "%02d:%02d:%02d ", st.wHour, st.wMinute, st.wSecond);
    va_list ap; va_start(ap, fmt); vfprintf(f, fmt, ap); va_end(ap);
    fputc('\n', f);
    fclose(f);
}

// смещения, проверенные по коду функции перед установкой
#define OFF_EXT_WEAKCAP   0x28   // обработчик: слабая ссылка на свою съёмку
#define OFF_CAP_MARGINC   0x8b8  // съёмка: SphereMarginConstant
#define OFF_CAP_TEXTURE   0x2c0  // съёмка: TextureTarget

static int isMarked(float m) { return m == 0.25f || m == 0.5625f || m == 0.625f; }

static void *volatile g_mainExt;   // обработчик основной съёмки (для вывода половин)
static volatile LONG g_skipLogged;
static void hook(void *ext, void *graph, void *view, void *inputs, void *out) {
    void *cap = g_weakGet((char *)ext + OFF_EXT_WEAKCAP);
    if (cap) {
        // без текстуры игра всё равно заводит проход вклеивания — и он падает
        if (!*(void **)((char *)cap + OFF_CAP_TEXTURE)) return;
        if (isMarked(*(float *)((char *)cap + OFF_CAP_MARGINC))) {
            g_mainExt = ext;
            void *fam = *(void **)view;
            void **views = fam ? *(void ***)fam : NULL;
            int n = (fam && views) ? *(int *)((char *)fam + 8) : 0;
            if (n > 1 && n <= 8 && views[0] != view) {   // не первая половина
                if (InterlockedCompareExchange(&g_skipLogged, 1, 0) == 0) logmsg("вклеивание: только в первую половину");
                return;
            }
        }
    }
    g_orig(ext, graph, view, inputs, out);
}

// РИСУЕМ СЛЕВА, ПОКАЗЫВАЕМ СПРАВА. Свой ореол игра верно рисует только в
// половине, что лежит в начале кадра (слева/сверху): её шейдер берёт глубину и
// прочее без сдвига половины. Мод ставит держащего куклу первым — он рисуется
// слева/сверху, — а если по положению героев ему место справа/снизу, ставит
// основной съёмке метку 0.5625 (слева/справа) или 0.625 (сверху/снизу). Тогда
// здесь, уже после того как движок разложил виды в буфере кадра, меняем
// местами только места ВЫВОДА видов (UnscaledViewRect): готовая картинка
// каждой половины ложится на нужную сторону экрана.
#define OFF_VIEW_OUTRECT 0x258   // FSceneView::UnscaledViewRect (место вида в итоговом кадре)
static volatile LONG g_outLogged;
// Место вывода (UnscaledViewRect) постобработка берёт в самом начале своей
// сборки (AddPostProcessingPasses) — меняем его на входе в неё. Место вида в
// буфере кадра (ViewRect) к этому времени уже посчитано и не меняется.
static volatile LONG g_methodLogged;
// ВЫВОД ПОЛОВИН ВНЕ ДВУХ МИРОВ. Чтобы каждый игрок был на своей стороне, мод
// раньше ставил игрока 2 первым в списке локальных игроков. Но ролики движка
// (смена камер в LevelSequence) отдают камеру первому локальному игроку — и
// вид игрока 2 уходил на камеру ролика: обе половины показывали Low. Теперь
// порядок игроков не трогается, а места вывода меняет эта библиотека. Указание
// мод пишет в файл split_out.txt рядом с библиотекой: 0 — как нарисованы,
// 1 — поменять слева/справа, 2 — сверху/снизу. Поток ниже ждёт изменения
// файла (уведомление Windows о папке) и читает его.
static volatile LONG g_fileMode;
static char g_mailPath[MAX_PATH], g_dirPath[MAX_PATH];
static volatile LONG g_fileLogged = -1;
static void readMail(void) {
    for (int i = 0; i < 5; i++) {
        FILE *f = fopen(g_mailPath, "rb");
        if (f) {
            int c = fgetc(f); fclose(f);
            LONG m = (c == '1') ? 1 : (c == '2') ? 2 : 0;
            InterlockedExchange(&g_fileMode, m);
            if (InterlockedExchange(&g_fileLogged, m) != m)
                logmsg("вывод половин (без двух миров): %s", m == 1 ? "меняю слева/справа" : m == 2 ? "меняю сверху/снизу" : "как нарисованы");
            return;
        }
        Sleep(2);   // файл в этот момент пишет мод
    }
}
static DWORD WINAPI mailThread(LPVOID arg) {
    (void)arg;
    HANDLE h = FindFirstChangeNotificationA(g_dirPath, FALSE, FILE_NOTIFY_CHANGE_LAST_WRITE | FILE_NOTIFY_CHANGE_FILE_NAME | FILE_NOTIFY_CHANGE_SIZE);
    if (h == INVALID_HANDLE_VALUE) { logmsg("ошибка: не слежу за файлом указаний — вывод половин без двух миров недоступен"); return 0; }
    readMail();
    for (;;) {
        if (WaitForSingleObject(h, INFINITE) != WAIT_OBJECT_0) break;
        readMail();
        if (!FindNextChangeNotification(h)) break;
    }
    FindCloseChangeNotification(h);
    return 0;
}
static void __cdecl beforePostProcess(void *view) {
    if (!view) return;
    float mk = 0;
    LONG fm = g_fileMode;
    if (fm == 1) mk = 0.5625f;
    else if (fm == 2) mk = 0.625f;
    else {
        void *ext = g_mainExt; if (!ext) return;
        void *cap = g_weakGet((char *)ext + OFF_EXT_WEAKCAP); if (!cap) return;
        mk = *(float *)((char *)cap + OFF_CAP_MARGINC);
    }
    if (mk != 0.5625f && mk != 0.625f) return;
    void *fam = *(void **)view;
    if (!fam || *(int *)((char *)fam + 8) != 2) return;
    if (*(int *)((char *)view + 0x15f4) == 2) {   // вывод берётся из места в буфере — так не умеем
        if (InterlockedCompareExchange(&g_methodLogged, 1, 0) == 0) logmsg("вывод половин: у вида вывод по месту в буфере — менять нельзя");
        return;
    }
    int *r = (int *)((char *)view + OFF_VIEW_OUTRECT);
    if (mk == 0.5625f) { int w = r[2] - r[0]; if (r[0] == 0) { r[0] += w; r[2] += w; } else { r[0] -= w; r[2] -= w; } }
    else               { int h = r[3] - r[1]; if (r[1] == 0) { r[1] += h; r[3] += h; } else { r[1] -= h; r[3] -= h; } }
    if (InterlockedCompareExchange(&g_outLogged, 1, 0) == 0) logmsg("вывод половин: меняю местами (вид выводится в %d %d %d %d)", r[0], r[1], r[2], r[3]);
}
// перехват входа в AddPostProcessingPasses: первые 20 байт функции — без
// ссылок на адреса (mov r11,rsp; push rbp; push r13; lea rbp,[r11-738h];
// sub rsp,828h); переносим их в «трамплин», на их место — переход к заглушке
static int installPostHook(unsigned char *fn) {
    static const unsigned char head[20] = { 0x4c,0x8b,0xdc,0x55,0x41,0x55,0x49,0x8d,0xab,0xc8,0xf8,0xff,0xff,0x48,0x81,0xec,0x28,0x08,0x00,0x00 };
    if (memcmp(fn, head, 20) != 0) return 0;
    unsigned char *mem = (unsigned char *)VirtualAlloc(NULL, 256, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE);
    if (!mem) return 0;
    unsigned char *tr = mem, *st = mem + 64;
    // трамплин: исходные 20 байт + jmp [rip+0] → fn+20
    memcpy(tr, head, 20);
    tr[20] = 0xff; tr[21] = 0x25; *(int *)(tr + 22) = 0; *(unsigned long long *)(tr + 26) = (unsigned long long)(fn + 20);
    // заглушка: сохранить аргументы, beforePostProcess(rdx = вид), вернуть, в трамплин
    unsigned char *p = st;
    *p++ = 0x51; *p++ = 0x52; *p++ = 0x41; *p++ = 0x50; *p++ = 0x41; *p++ = 0x51;          // push rcx, rdx, r8, r9
    *p++ = 0x48; *p++ = 0x83; *p++ = 0xec; *p++ = 0x28;                                    // sub rsp, 28h
    *p++ = 0x48; *p++ = 0x89; *p++ = 0xd1;                                                 // mov rcx, rdx
    *p++ = 0x48; *p++ = 0xb8; *(unsigned long long *)p = (unsigned long long)beforePostProcess; p += 8; // mov rax, imm64
    *p++ = 0xff; *p++ = 0xd0;                                                              // call rax
    *p++ = 0x48; *p++ = 0x83; *p++ = 0xc4; *p++ = 0x28;                                    // add rsp, 28h
    *p++ = 0x41; *p++ = 0x59; *p++ = 0x41; *p++ = 0x58; *p++ = 0x5a; *p++ = 0x59;          // pop r9, r8, rdx, rcx
    *p++ = 0xff; *p++ = 0x25; *(int *)p = 0; p += 4; *(unsigned long long *)p = (unsigned long long)tr; p += 8; // jmp tr
    FlushInstructionCache(GetCurrentProcess(), mem, 256);
    DWORD old;
    if (!VirtualProtect(fn, 14, PAGE_EXECUTE_READWRITE, &old)) return 0;
    unsigned char j[14] = { 0xff, 0x25, 0, 0, 0, 0 };
    *(unsigned long long *)(j + 6) = (unsigned long long)st;
    memcpy(fn, j, 14);
    VirtualProtect(fn, 14, old, &old);
    FlushInstructionCache(GetCurrentProcess(), fn, 14);
    return 1;
}

static int match(const unsigned char *p, const char *pat) {
    // pat: "4c 8b ?? ..."
    while (*pat) {
        while (*pat == ' ') pat++;
        if (!*pat) break;
        if (pat[0] == '?') { pat += 2; p++; continue; }
        unsigned v; sscanf(pat, "%2x", &v);
        if (*p != (unsigned char)v) return 0;
        pat += 2; p++;
    }
    return 1;
}

static DWORD WINAPI init(LPVOID arg) {
    (void)arg;
    unsigned char *base = (unsigned char *)GetModuleHandleW(NULL);
    IMAGE_NT_HEADERS *nt = (IMAGE_NT_HEADERS *)(base + ((IMAGE_DOS_HEADER *)base)->e_lfanew);
    IMAGE_SECTION_HEADER *sec = IMAGE_FIRST_SECTION(nt);
    const char *sig =
        "4c 8b dc 55 56 57 41 54 41 57 49 8d ab b8 fe ff ff 48 81 ec 20 02 00 00 "
        "48 8b 05 ?? ?? ?? ?? 48 33 c4 48 89 45 78 48 8b 05 ?? ?? ?? ?? 4d 8b e1 49 8b f0 "
        "48 89 55 10 4c 8b fa 48 8b f9 80 78 01 00 0f 84";
    unsigned char *fn = NULL;
    for (int s = 0; s < nt->FileHeader.NumberOfSections && !fn; s++) {
        if (!(sec[s].Characteristics & IMAGE_SCN_MEM_EXECUTE)) continue;
        unsigned char *p = base + sec[s].VirtualAddress, *e = p + sec[s].Misc.VirtualSize - 0x700;
        for (; p < e; p++) if (p[0] == 0x4c && p[1] == 0x8b && p[2] == 0xdc && match(p, sig)) { fn = p; break; }
    }
    if (!fn) { logmsg("ошибка: функция вклеивания второго мира не найдена (другая версия игры?) — ничего не меняю"); return 0; }
    // проверки: вызов взятия слабой ссылки и чтение SphereMarginConstant там, где ожидаем
    if (!match(fn + 0x6b, "48 8d 4f 28 e8") || !match(fn + 0x635, "f3 41 0f 58 9e b8 08 00 00")) {
        logmsg("ошибка: функция вклеивания не такая, как ожидалось — ничего не меняю"); return 0;
    }
    g_weakGet = (WeakGetFn)(fn + 0x6f + 5 + *(int *)(fn + 0x70));
    // ячейка таблицы виртуальных функций, где лежит адрес функции
    void **slot = NULL; int hits = 0;
    for (int s = 0; s < nt->FileHeader.NumberOfSections; s++) {
        if (sec[s].Characteristics & IMAGE_SCN_MEM_EXECUTE) continue;
        if (!(sec[s].Characteristics & IMAGE_SCN_MEM_READ)) continue;
        void **p = (void **)(base + sec[s].VirtualAddress), **e = (void **)(base + sec[s].VirtualAddress + sec[s].Misc.VirtualSize - 8);
        for (; p < e; p++) if (*p == fn) { slot = p; hits++; }
    }
    if (hits != 1) { logmsg("ошибка: ячеек таблицы с функцией вклеивания %d (нужна одна) — ничего не меняю", hits); return 0; }
    g_orig = (CompositeFn)fn;
    DWORD old;
    if (!VirtualProtect(slot, sizeof(void *), PAGE_READWRITE, &old)) { logmsg("ошибка: не открыть таблицу на запись"); return 0; }
    InterlockedExchangePointer(slot, (void *)hook);
    VirtualProtect(slot, sizeof(void *), old, &old);
    logmsg("установлено: вклеивание второго мира (функция %p)", fn);
    // вход в сборку постобработки: та же голова и чтение места в буфере (+1698h) и вывода (+258h)
    {
        unsigned char *pp = NULL; int cnt = 0;
        for (int s2 = 0; s2 < nt->FileHeader.NumberOfSections; s2++) {
            if (!(sec[s2].Characteristics & IMAGE_SCN_MEM_EXECUTE)) continue;
            unsigned char *p = base + sec[s2].VirtualAddress, *e = p + sec[s2].Misc.VirtualSize - 0x100;
            for (; p < e; p++)
                if (p[0] == 0x4c && p[1] == 0x8b && p[2] == 0xdc &&
                    match(p, "4c 8b dc 55 41 55 49 8d ab c8 f8 ff ff 48 81 ec 28 08 00 00") &&
                    match(p + 0x80, "48 8d 9f 98 16 00 00") && match(p + 0xbb, "48 8d 9f 58 02 00 00")) { pp = p; cnt++; }
        }
        if (cnt == 1 && installPostHook(pp)) {
            logmsg("установлено: вывод половин (сборка постобработки %p)", pp);
            // мод узнаёт по этому файлу, что менять места вывода можно
            FILE *ok = fopen(g_okPath, "wb"); if (ok) { fputs("1", ok); fclose(ok); }
            CloseHandle(CreateThread(NULL, 0, mailThread, NULL, 0, NULL));
        }
        else logmsg("сборка постобработки не найдена (%d) — вывод половин недоступен", cnt);
    }
    return 0;
}

BOOL WINAPI DllMain(HINSTANCE h, DWORD reason, LPVOID r) {
    (void)r;
    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(h);
        GetModuleFileNameA(h, g_logPath, MAX_PATH);
        char *dot = strrchr(g_logPath, '.');
        if (dot) strcpy(dot, ".log"); else strcat(g_logPath, ".log");
        // папка библиотеки: файл указаний и отметка «вывод половин работает»
        strcpy(g_dirPath, g_logPath);
        char *sl = strrchr(g_dirPath, '\\'); if (!sl) sl = strrchr(g_dirPath, '/');
        if (sl) *sl = 0; else strcpy(g_dirPath, ".");
        snprintf(g_mailPath, MAX_PATH, "%s\\split_out.txt", g_dirPath);
        snprintf(g_okPath, MAX_PATH, "%s\\split_out.ok", g_dirPath);
        DeleteFileA(g_okPath);
        CloseHandle(CreateThread(NULL, 0, init, NULL, 0, NULL));
    }
    return TRUE;
}
