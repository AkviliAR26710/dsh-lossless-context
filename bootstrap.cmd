@echo off
chcp 65001 >nul
title DSH 一键重建配置
echo.
echo   正在根据 settings.json 重建配置...
echo   （DSH 更新后跑这个就够了）
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0bootstrap.ps1" %*
