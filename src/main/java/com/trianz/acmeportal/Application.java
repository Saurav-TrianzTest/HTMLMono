package com.trianz.acmeportal;

import com.sun.net.httpserver.HttpServer;
import java.net.InetSocketAddress;

/**
 * Minimal backend entry point for the acme-portal-static fixture.
 * Uses only built-in JDK APIs so the module builds without external
 * dependencies or network access.
 */
public class Application {

    public static void main(String[] args) throws Exception {
        int port = 8080;
        HttpServer server = HttpServer.create(new InetSocketAddress(port), 0);
        server.createContext("/api/health", new HealthHandler());
        server.setExecutor(null);
        server.start();
        System.out.println("acme-portal-static backend listening on port " + port);
    }
}
