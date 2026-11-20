int mshell_spawn(const char *shell, const char *directory, int rows, int columns, int *descriptor);
void mshell_resize(int descriptor, int rows, int columns);
void mshell_stop(int pid);
