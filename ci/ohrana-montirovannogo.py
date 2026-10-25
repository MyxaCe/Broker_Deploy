#!/usr/bin/env python3
"""Примонтированный каталог не удаляют. B-OPS-034.

ЧТО ПРОИЗОШЛО. 24.10 я заменил содержимое `server/monitoring/conf`
через `rm -rf conf && tar xzf -`. Bind-mount каталога держится за ЕГО
inode так же, как у файла: контейнеры остались смотреть в каталог,
которого больше нет. Prometheus потерял ВСЕ правила и отчитался об
успешной перезагрузке. Наблюдение стояло слепым, и слепое оно выглядело
ровно как спокойное.

Запрет я тогда написал комментарием рядом с местом соблазна. Комментарий
— не механизм: он обращён к тому, кто читает, а удаляет тот, кто спешит.

ЧТО ИМЕННО ЗАПРЕЩЕНО — И ЧТО НЕТ. Запрещено УДАЛЕНИЕ каталога, который
`compose.yml` рядом отдаёт контейнеру bind-монтированием. Не запрещено
его упоминать: предупреждение, объясняющее запрет, обязано называть то,
что запрещает, иначе оно безымянное.

Эту разницу витрина уже решила в своём стороже сожжённых секретов
(`packages/utils/src/burned-secrets.test.ts`): первая редакция различала
предупреждение и предложение по знаку комментария, в Markdown это не
работает, и сторож покрасил текст, ради которого писался. Там стали
различать ФОРМУ ПРИСВАИВАНИЯ. Здесь — ровно та же мысль в своей огранке:
различается ФОРМА ВЫЗОВА. `rm` в позиции команды есть употребление;
`rm`, названный в прозе или внутри кавычек, — упоминание.

ОТКУДА БЕРЁТСЯ СПИСОК ЗАЩИЩЁННОГО. Из `compose.yml`, а не из списка
руками: список руками отстал бы от компоуза молча, и новый монтируемый
каталог просто не попал бы под охрану — это находка OPS-16, повторять
её в инструменте, написанном против неё, нельзя.

Запуск:  python3 ci/ohrana-montirovannogo.py
"""

import os
import re
import sys

# Корень берётся из аргумента, чтобы сторожа можно было прогнать над
# синтетическим деревом. Без этого «проверка умеет краснеть» доказывалась
# бы порчей настоящего файла — то есть не доказывалась бы.
KOREN = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 \
    else os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# `rm` в ПОЗИЦИИ КОМАНДЫ: начало строки, либо сразу после разделителя
# команд. После `&&`, `;`, `|`, `(`, `then`, `do`, `else` идёт команда;
# в прозе и в кавычках — нет.
NACHALO = r'(?:^|[;&|(]|\&\&|\|\||\bthen\b|\bdo\b|\belse\b)\s*'
VYZOV = re.compile(NACHALO + r'(?:sudo\s+)?rm\s+(-[A-Za-z]*r[A-Za-z]*\s+)+(?P<celi>.*)$')


def bez_kommentariev(stroka: str) -> str:
    """Отрезает комментарий, не трогая `#` внутри кавычек.

    Простое `split('#')` съело бы `rm -rf "$D/a#b"`, а строку-предупреждение
    пропустило бы одинаково — то есть ошиблось бы в обе стороны сразу.
    """
    v_odinarnyh = v_dvojnyh = False
    for i, c in enumerate(stroka):
        if c == "'" and not v_dvojnyh:
            v_odinarnyh = not v_odinarnyh
        elif c == '"' and not v_odinarnyh:
            v_dvojnyh = not v_dvojnyh
        elif c == '#' and not v_odinarnyh and not v_dvojnyh:
            # `#` в середине слова — это не начало комментария.
            if i == 0 or stroka[i - 1].isspace():
                return stroka[:i]
    return stroka


def montirovannye(kat: str) -> set:
    """Каталоги, которые compose.yml в этом каталоге отдаёт контейнерам.

    Разбор строчный, а не через YAML: нужен ИСХОДНЫЙ текст пути со
    слешами, а не то, во что его превратит загрузчик. Зависимость от
    pyyaml здесь была бы лишней.
    """
    put = os.path.join(kat, 'compose.yml')
    if not os.path.isfile(put):
        return set()
    out = set()
    with open(put, encoding='utf-8') as f:
        for stroka in f:
            m = re.match(r"\s*-\s+(\./[^:'\"]+):", bez_kommentariev(stroka))
            if m:
                out.add(m.group(1)[2:].rstrip('/'))
    return out


def skripty() -> list:
    out = []
    for koren, kat, fajly in os.walk(os.path.join(KOREN, 'server')):
        kat[:] = [d for d in kat if d not in ('.git', 'rendered')]
        for f in fajly:
            if f.endswith('.sh'):
                out.append(os.path.join(koren, f))
    return sorted(out)


def narusheniya(put: str, text: str, zashchishcheno: set) -> list:
    """Строки, удаляющие защищённый каталог."""
    out = []
    for n, syraya in enumerate(text.split('\n'), 1):
        stroka = bez_kommentariev(syraya)
        m = VYZOV.search(stroka)
        if not m:
            continue
        celi = m.group('celi')
        for d in zashchishcheno:
            # Совпадение по сегменту пути, а не по подстроке: `conf`
            # не должен ловиться в `configs` и в `conf.bak`.
            #
            # Конец сегмента — это не только слеш, кавычка и пробел.
            # Первая редакция перечисляла только их, и `rm -rf conf; fi`
            # внутри `if` прошло как чистое: цель кончалась точкой с
            # запятой, а её в списке не было. Поймано стендом — ровно для
            # этого он и перечисляет огранки по одной.
            if re.search(r'(^|[/"\'$}\s])' + re.escape(d) + r'([/"\'\s;)&|]|$)', celi):
                out.append((n, d, syraya.strip()))
                break
    return out


def main() -> int:
    osmotreno = 0
    pod_ohranoj = 0
    najdeno = []

    for put in skripty():
        kat = os.path.dirname(put)
        zashchishcheno = montirovannye(kat)
        osmotreno += 1
        if not zashchishcheno:
            continue
        pod_ohranoj += 1
        with open(put, encoding='utf-8') as f:
            text = f.read()
        for n, d, stroka in narusheniya(put, text, zashchishcheno):
            najdeno.append('%s:%d: удаление примонтированного «%s»: %s'
                           % (os.path.relpath(put, KOREN).replace(os.sep, '/'), n, d, stroka))

    # ОХВАТ ПЕЧАТАЕТСЯ ЧИСЛОМ. Ноль осмотренных скриптов — это не
    # «нарушений нет», а «проверка не нашла, что проверять», и она
    # обязана на этом падать, а не молчать зелёным.
    print('осмотрено скриптов: %d, из них под охраной (рядом есть compose.yml): %d'
          % (osmotreno, pod_ohranoj))
    if osmotreno == 0 or pod_ohranoj == 0:
        print('ПРОВАЛ: проверять оказалось нечего — сторож без охвата не сторожит',
              file=sys.stderr)
        return 1

    if najdeno:
        print('ПРОВАЛ: примонтированный каталог удаляют —', file=sys.stderr)
        for s in najdeno:
            print('  ' + s, file=sys.stderr)
        print('  bind-mount держится за inode каталога: после удаления контейнер',
              file=sys.stderr)
        print('  смотрит в несуществующее и молчит. Распаковывайте ПОВЕРХ.',
              file=sys.stderr)
        return 1

    print('нарушений нет')
    return 0


if __name__ == '__main__':
    sys.exit(main())
