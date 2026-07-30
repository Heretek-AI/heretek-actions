FROM ubuntu:latest
RUN apt-get update && apt-get install -y curl
ADD http://example.com/binary /usr/local/bin/binary
RUN chmod +x /usr/local/bin/binary && /usr/local/bin/binary
ENTRYPOINT ["bash"]
