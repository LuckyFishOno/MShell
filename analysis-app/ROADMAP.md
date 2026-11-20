# MShell roadmap

## SSH and terminal

- [ ] SSH agent support, more private-key formats, and multi-hop jump hosts.
- [ ] Reverse and dynamic port forwarding, with saved forwarding rules.
- [ ] Connection recovery after sleep and optional automatic reconnect.
- [x] Two terminal panes, with side-by-side and stacked layouts.
- [ ] Quick commands, broadcast input, and session logs.
- [ ] Broader terminal compatibility testing with Vim, tmux, and Chinese input methods.

## Other connections

- [ ] **Windows Remote Desktop (RDP)**. Save an RDP connection in the session tree and open it from MShell. Verify authentication, display resizing, keyboard, and pointer input.
- [ ] **macOS serial ports**. Open a built-in or USB serial device. Configure baud rate, data bits, parity, stop bits, and flow control. Handle device removal and reconnection.
