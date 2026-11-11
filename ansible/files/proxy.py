#!/usr/bin/env python3
import argparse
import configparser
import logging
import select
import socket
import sys
import threading

def parse_config(config_path):
    config = configparser.ConfigParser()
    config.read(config_path)
    listen_port = config.getint('proxy', 'listen_port', fallback=8080)
    forward_to = config.get('proxy', 'forward_to', fallback='127.0.0.1:9000')
    log_file = config.get('proxy', 'log_file', fallback='/var/log/proxy/proxy.log')
    return listen_port, forward_to, log_file

def handle_client(client_sock, remote_host, remote_port):
    try:
        remote_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        remote_sock.connect((remote_host, remote_port))
    except Exception as e:
        logging.error(f"Impossible de se connecter à la destination {remote_host}:{remote_port} : {e}")
        client_sock.close()
        return

    sockets = [client_sock, remote_sock]
    while True:
        readable, _, _ = select.select(sockets, [], [], 60)
        if not readable:
            break
        try:
            for sock in readable:
                other = remote_sock if sock is client_sock else client_sock
                data = sock.recv(4096)
                if not data:
                    break
                other.sendall(data)
        except Exception:
            break

    client_sock.close()
    remote_sock.close()

def main():
    parser = argparse.ArgumentParser(description="Proxy Chain Node")
    parser.add_argument("--config", required=True, help="Chemin vers le fichier de configuration")
    args = parser.parse_args()

    listen_port, forward_to, log_file = parse_config(args.config)
    remote_host, remote_port = forward_to.split(':')
    remote_port = int(remote_port)

    logging.basicConfig(
        filename=log_file,
        level=logging.INFO,
        format='%(asctime)s - %(levelname)s - %(message)s'
    )

    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        server.bind(('0.0.0.0', listen_port))
        server.listen(100)
        logging.info(f"Proxy démarré sur le port {listen_port}, transfert vers {remote_host}:{remote_port}")
    except Exception as e:
        logging.critical(f"Erreur lors du bind sur le port {listen_port} : {e}")
        sys.exit(1)

    while True:
        client_sock, addr = server.accept()
        logging.info(f"Connexion entrante depuis {addr[0]}:{addr[1]}")
        client_thread = threading.Thread(target=handle_client, args=(client_sock, remote_host, remote_port))
        client_thread.daemon = True
        client_thread.start()

if __name__ == '__main__':
    main()
