@echo off
REM 在仓库根目录生成 id_vast_ed25519 / id_vast_ed25519.pub（无密钥口令）
REM 用法：双击本文件，或在 CMD 里执行: scripts\gen-vast-ssh-key.cmd

cd /d "%~dp0.."
echo 将在目录生成:
echo   %CD%\id_vast_ed25519
echo   %CD%\id_vast_ed25519.pub
echo.
ssh-keygen -t ed25519 -C "vast-pffthash" -f "%CD%\id_vast_ed25519" -q -N ""
if errorlevel 1 (
  echo ssh-keygen 失败。请确认已安装 OpenSSH 客户端（Windows 可选功能）。
  pause
  exit /b 1
)
echo.
echo 完成。请把下面文件内容整行复制到 vast 网站 SSH Keys:
type "%CD%\id_vast_ed25519.pub"
echo.
pause
