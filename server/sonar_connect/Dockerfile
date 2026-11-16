FROM python:3.12-alpine
WORKDIR /app
COPY relay.py discover.py ./
# No packages: standard library only. /state holds Discover's list of removed
# songs (a named volume takes this folder's owner when first created).
RUN adduser -D -H relay && mkdir /state && chown relay /state
USER relay
ENV PORT=4534 NAVIDROME_URL=http://navidrome:4533 PYTHONUNBUFFERED=1
EXPOSE 4534
HEALTHCHECK --interval=60s --timeout=5s CMD wget -qO- http://127.0.0.1:4534/health || exit 1
CMD ["python", "relay.py"]
