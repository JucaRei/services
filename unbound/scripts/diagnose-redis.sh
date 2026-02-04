#!/bin/sh
# Script de diagnóstico para conexão Redis do Unbound

echo "=== DIAGNÓSTICO REDIS UNBOUND ==="
echo "Data: $(date)"
echo ""

# 1. Testar conexão Redis
echo "1. Testando conexão Redis..."
if docker exec unbound-db redis-cli ping > /dev/null 2>&1; then
    echo "✅ Redis respondendo"
    REDIS_STATUS="OK"
else
    echo "❌ Redis não respondendo"
    REDIS_STATUS="FAIL"
fi

# 2. Verificar permissões do socket
echo ""
echo "2. Verificando permissões do socket..."
if [ -S /var/run/redis/redis.sock ]; then
    echo "✅ Socket Redis existe"
    ls -la /var/run/redis/redis.sock
else
    echo "❌ Socket Redis não encontrado"
fi

# 3. Testar comunicação Unbound-Redis
echo ""
echo "3. Testando comunicação Unbound-Redis..."
if docker exec unbound unbound-control stats > /dev/null 2>&1; then
    echo "✅ Unbound-control funcionando"
    UNBOUND_STATUS="OK"
else
    echo "❌ Unbound-control falhou"
    UNBOUND_STATUS="FAIL"
fi

# 4. Verificar cache Redis
echo ""
echo "4. Verificando cache Redis..."
if [ "$REDIS_STATUS" = "OK" ]; then
    CACHE_SIZE=$(docker exec unbound-db redis-cli dbsize 2>/dev/null || echo "0")
    echo "Tamanho do cache Redis: $CACHE_SIZE registros"
    
    if [ "$CACHE_SIZE" -gt 0 ]; then
        echo "✅ Cache Redis contém dados"
    else
        echo "⚠️  Cache Redis está vazio"
    fi
fi

# 5. Verificar logs do Unbound
echo ""
echo "5. Verificando logs do Unbound..."
if [ -f /var/log/unbound-stats/unbound.log ]; then
    LOG_LINES=$(wc -l < /var/log/unbound-stats/unbound.log)
    echo "Arquivo de log encontrado com $LOG_LINES linhas"
    
    # Verificar erros recentes
    ERROR_COUNT=$(grep -c "error\|Error\|ERROR" /var/log/unbound-stats/unbound.log 2>/dev/null || echo "0")
    echo "Erros encontrados: $ERROR_COUNT"
else
    echo "❌ Arquivo de log não encontrado"
fi

# 6. Verificar volumes compartilhados
echo ""
echo "6. Verificando volumes compartilhados..."
echo "Volume cachedb.d:"
ls -la /usr/local/unbound/cachedb.d/ 2>/dev/null || echo "❌ Volume não acessível"

echo ""
echo "Volume log.d:"
ls -la /usr/local/unbound/log.d/ 2>/dev/null || echo "❌ Volume não acessível"

# 7. Resumo
echo ""
echo "=== RESUMO DO DIAGNÓSTICO ==="
echo "Redis Status: $REDIS_STATUS"
echo "Unbound Status: $UNBOUND_STATUS"

if [ "$REDIS_STATUS" = "FAIL" ] || [ "$UNBOUND_STATUS" = "FAIL" ]; then
    echo "🚨 PROBLEMAS CRÍTICOS DETECTADOS"
    echo "Solução recomendada: Reiniciar containers e verificar configuração"
else
    echo "✅ Sistema aparentemente funcional"
    echo "Problema pode estar na configuração de cache ou políticas de segurança"
fi

echo ""
echo "=== FIM DO DIAGNÓSTICO ==="