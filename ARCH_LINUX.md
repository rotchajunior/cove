# Suporte ao Arch Linux e Manjaro no Cove 🏝️

Este documento descreve as alterações implementadas neste fork para adicionar compatibilidade completa com **Arch Linux**, **Manjaro** e outras distribuições baseadas em Arch.

---

## 📋 Resumo das Alterações

O projeto original do Cove ([anchorhost/cove](https://github.com/anchorhost/cove)) oferecia suporte oficial apenas a macOS (`brew`), Debian/Ubuntu (`apt`) e Fedora/RHEL (`dnf`).

Neste fork, foram adicionados:

1. **Detecção de Sistema Operacional & `pacman`**:
   - Reconhecimento automático de `ID=arch`, `ID=manjaro` e `ID_LIKE=arch` via `/etc/os-release`.
   - Mapeamento do gerenciador de pacotes para `PKG_MANAGER="pacman"`.

2. **Mapeamento de Dependências com `pacman`**:
   - `gum`: Instalado via `pacman -S --needed --noconfirm gum` (repositório `extra`).
   - `mariadb`: Instalado via `pacman -S --needed --noconfirm mariadb mariadb-clients`.
   - `wp-cli`: Instalado via `pacman -S --needed --noconfirm wp-cli`.
   - `nss`: Ferramentas NSS (`certutil`) instaladas via `pacman -S --needed --noconfirm nss`.
   - `cloudflared`: Instalado via `pacman -S --needed --noconfirm cloudflared` (para `cove share`).

3. **Inicialização Automática do MariaDB**:
   - No Arch/Manjaro, a instalação do MariaDB não inicializa automaticamente a pasta `/var/lib/mysql`.
   - O instalador agora detecta se `/var/lib/mysql/mysql` existe e, se necessário, executa:
     ```bash
     sudo mariadb-install-db --user=mysql --basedir=/usr --datadir=/var/lib/mysql
     ```

4. **Autodetecção do Socket UNIX do MariaDB no PHP**:
   - O MariaDB no Arch/Manjaro expõe o socket em `/run/mysqld/mysqld.sock`.
   - O `cove install` agora detecta o caminho do socket ativo no sistema e o injeta automaticamente no `~/Cove/php.ini`:
     ```ini
     mysqli.default_socket = /run/mysqld/mysqld.sock
     pdo_mysql.default_socket = /run/mysqld/mysqld.sock
     ```
   - Isso evita o erro de conexão `Database connection error (2002)` ao rodar o WP-CLI ou acessar o banco.

5. **Confiança de Certificados SSL nos Navegadores (`cove trust`)**:
   - O comando `cove trust` agora busca os bancos de dados NSS também em `~/.pki/nssdb` (padrão de navegadores Chromium/Chrome no Arch Linux), além dos perfis do Firefox.

---

## 🛠️ Arquivos Modificados

- [`install-cove.sh`](install-cove.sh): Adicionada detecção do `pacman` no instalador standalone.
- [`main`](main): Adicionado suporte a distribuições baseadas em Arch no script central.
- [`commands/install`](commands/install): Suporte a pacman em `install_dependency`, inicialização do MariaDB e injeção do socket no `php.ini`.
- [`commands/trust`](commands/trust): Suporte a pacote `nss` no Arch e inclusão de `~/.pki` na varredura de certificados.
- [`commands/share`](commands/share): Instalação do `cloudflared` via `pacman`.
- [`commands/upgrade`](commands/upgrade): Suporte a atualização do `frankenphp` via `pacman` ou binário estático.
- [`commands/transfer`](commands/transfer): Fallback de instalação de pacotes remotos via `pacman`.
- [`cove.sh`](cove.sh): Script final recompilado gerado por `./compile.sh`.

---

## 🚀 Como Instalar e Compilar

### 1. Pré-requisitos
```bash
sudo pacman -S --needed gum mariadb mariadb-clients nss libcap curl
```

### 2. Compilar e Instalar
```bash
# Compilar os fontes (main + commands/* -> cove.sh)
./compile.sh

# Instalar no sistema (/usr/local/bin/cove)
sudo ./install-cove.sh --dev
```

---

## 🔄 Como Manter Este Fork Atualizado com o Projeto Original (Upstream)

Para sincronizar novas atualizações lançadas pelo repositório original do Cove:

### 1. Configurar o repositório upstream (uma única vez)
```bash
git remote add upstream https://github.com/anchorhost/cove.git
git remote -v
```

### 2. Buscar atualizações e mesclar
```bash
# Baixar alterações do projeto original
git fetch upstream

# Mesclar as atualizações na sua branch principal
git merge upstream/main

# Recompilar o executável
./compile.sh

# Atualizar o binário do sistema
sudo cp cove.sh /usr/local/bin/cove
```
