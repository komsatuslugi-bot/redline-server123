FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV GODOT_VERSION=4.6-stable

RUN apt-get update && apt-get install -y \
    ca-certificates \
    libfontconfig1 \
    wget \
    unzip \
    && rm -rf /var/lib/apt/lists/*

RUN wget -O /tmp/godot.zip "https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}/Godot_v${GODOT_VERSION}_linux.x86_64.zip" \
    && unzip /tmp/godot.zip -d /opt/godot \
    && rm /tmp/godot.zip \
    && mv /opt/godot/Godot_v${GODOT_VERSION}_linux.x86_64 /usr/local/bin/godot \
    && chmod +x /usr/local/bin/godot

WORKDIR /app
COPY . /app

ENV PORT=2457
EXPOSE 2457

CMD ["godot", "--headless", "--path", "/app", "--main-scene", "res://dedicated_server.tscn"]
