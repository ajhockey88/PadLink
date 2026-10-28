package com.padlink.receiver;

interface IGamepadService {
    // Shizuku calls this when the service is unbound; the transaction number is fixed by Shizuku.
    void destroy() = 16777114;

    // Creates the virtual gamepad and starts listening. An empty code means no pairing code.
    boolean start(int port, String code) = 1;

    void stop() = 2;

    // "state;packets;phoneIp;error" where state is idle, listening or connected.
    String status() = 3;
}
