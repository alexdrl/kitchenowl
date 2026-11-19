"""Usage: python gen_menu_widget_cards.py ../app/src/main/res/layout

Generates the two "today card + next days" layouts of the menu widget:
- menu_widget_wide.xml: wide and short (today on the left, next 3 days on the right)
- menu_widget_tall.xml: narrow and tall (today on top, next 4 days below)

The today card reuses the ids of menu_widget.xml (date, meal rows, message,
updated), so MenuWidgetProvider.kt fills all three with the same code. The
next-day rows are menu_widget_next<i> (+ _divider, _day, _lunch, _dinner);
the provider hides the ones the widget's height has no room for. Only
classes RemoteViews allows (no plain View).
"""
import os
import sys

MEALS = ["breakfast", "lunch", "dinner", "any"]


def today_card(indent, width, height, fill):
    p = " " * indent
    out = [
        f'{p}<LinearLayout',
        f'{p}    android:id="@+id/menu_widget_today_card"',
        f'{p}    android:layout_width="{width}"',
        f'{p}    android:layout_height="{height}"',
    ]
    if width == "0dp":
        out.append(f'{p}    android:layout_weight="{fill}"')
    out += [
        f'{p}    android:background="@drawable/menu_widget_today"',
        f'{p}    android:orientation="vertical"',
        f'{p}    android:paddingStart="14dp"',
        f'{p}    android:paddingTop="12dp"',
        f'{p}    android:paddingEnd="14dp"',
        f'{p}    android:paddingBottom="10dp">',
        f'{p}    <TextView',
        f'{p}        android:layout_width="wrap_content"',
        f'{p}        android:layout_height="wrap_content"',
        f'{p}        android:text="@string/menu_widget_today_label"',
        f'{p}        android:textColor="@color/menu_widget_accent"',
        f'{p}        android:textSize="11sp"',
        f'{p}        android:textStyle="bold" />',
        f'{p}    <TextView',
        f'{p}        android:id="@+id/menu_widget_date"',
        f'{p}        android:layout_width="match_parent"',
        f'{p}        android:layout_height="wrap_content"',
        f'{p}        android:ellipsize="end"',
        f'{p}        android:maxLines="1"',
        f'{p}        android:textColor="@color/menu_widget_text"',
        f'{p}        android:textSize="17sp"',
        f'{p}        android:textStyle="bold" />',
    ]
    for m in MEALS:
        out += [
            f'{p}    <LinearLayout',
            f'{p}        android:id="@+id/menu_widget_{m}"',
            f'{p}        android:layout_width="match_parent"',
            f'{p}        android:layout_height="wrap_content"',
            f'{p}        android:layout_marginTop="6dp"',
            f'{p}        android:orientation="vertical"',
            f'{p}        android:visibility="gone">',
            f'{p}        <TextView',
            f'{p}            android:id="@+id/menu_widget_{m}_label"',
            f'{p}            android:layout_width="wrap_content"',
            f'{p}            android:layout_height="wrap_content"',
            f'{p}            android:textColor="@color/menu_widget_accent"',
            f'{p}            android:textSize="12sp"',
            f'{p}            android:textStyle="bold" />',
            f'{p}        <TextView',
            f'{p}            android:id="@+id/menu_widget_{m}_text"',
            f'{p}            android:layout_width="match_parent"',
            f'{p}            android:layout_height="wrap_content"',
            f'{p}            android:ellipsize="end"',
            f'{p}            android:maxLines="2"',
            f'{p}            android:textColor="@color/menu_widget_text"',
            f'{p}            android:textSize="15sp" />',
            f'{p}    </LinearLayout>',
        ]
    out += [
        f'{p}    <TextView',
        f'{p}        android:id="@+id/menu_widget_message"',
        f'{p}        android:layout_width="match_parent"',
        f'{p}        android:layout_height="wrap_content"',
        f'{p}        android:layout_marginTop="8dp"',
        f'{p}        android:text="@string/menu_widget_open_app"',
        f'{p}        android:textColor="@color/menu_widget_text_secondary"',
        f'{p}        android:textSize="14sp" />',
    ]
    if height == "match_parent":
        out += [
            f'{p}    <FrameLayout',
            f'{p}        android:layout_width="match_parent"',
            f'{p}        android:layout_height="0dp"',
            f'{p}        android:layout_weight="1" />',
        ]
    out += [
        f'{p}    <TextView',
        f'{p}        android:id="@+id/menu_widget_updated"',
        f'{p}        android:layout_width="match_parent"',
        f'{p}        android:layout_height="wrap_content"',
        f'{p}        android:layout_marginTop="6dp"',
        f'{p}        android:maxLines="1"',
        f'{p}        android:textColor="@color/menu_widget_text_secondary"',
        f'{p}        android:textSize="10sp"',
        f'{p}        android:visibility="gone" />',
        f'{p}</LinearLayout>',
    ]
    return out


def meal_line(p, i, meal, icon):
    return [
        f'{p}<LinearLayout',
        f'{p}    android:layout_width="match_parent"',
        f'{p}    android:layout_height="wrap_content"',
        f'{p}    android:layout_marginTop="2dp"',
        f'{p}    android:gravity="center_vertical"',
        f'{p}    android:orientation="horizontal">',
        f'{p}    <ImageView',
        f'{p}        android:layout_width="14dp"',
        f'{p}        android:layout_height="14dp"',
        f'{p}        android:layout_marginEnd="6dp"',
        f'{p}        android:importantForAccessibility="no"',
        f'{p}        android:src="@drawable/menu_widget_{icon}" />',
        f'{p}    <TextView',
        f'{p}        android:id="@+id/menu_widget_next{i}_{meal}"',
        f'{p}        android:layout_width="match_parent"',
        f'{p}        android:layout_height="wrap_content"',
        f'{p}        android:ellipsize="end"',
        f'{p}        android:maxLines="1"',
        f'{p}        android:textColor="@color/menu_widget_text"',
        f'{p}        android:textSize="13sp" />',
        f'{p}</LinearLayout>',
    ]


def next_rows(indent, count, side_by_side):
    """Next days: the day label beside the meals (wide) or above them (tall)."""
    p = " " * indent
    out = [
        f'{p}<TextView',
        f'{p}    android:layout_width="match_parent"',
        f'{p}    android:layout_height="wrap_content"',
        f'{p}    android:paddingBottom="2dp"',
        f'{p}    android:text="@string/menu_widget_next_days"',
        f'{p}    android:textColor="@color/menu_widget_text_secondary"',
        f'{p}    android:textSize="13sp"',
        f'{p}    android:textStyle="bold" />',
    ]
    for i in range(count):
        out += [
            f'{p}<FrameLayout',
            f'{p}    android:id="@+id/menu_widget_next{i}_divider"',
            f'{p}    android:layout_width="match_parent"',
            f'{p}    android:layout_height="1dp"',
            f'{p}    android:layout_marginTop="5dp"',
            f'{p}    android:background="@color/menu_widget_divider" />',
            f'{p}<LinearLayout',
            f'{p}    android:id="@+id/menu_widget_next{i}"',
            f'{p}    android:layout_width="match_parent"',
            f'{p}    android:layout_height="wrap_content"',
            f'{p}    android:paddingTop="5dp"',
            f'{p}    android:orientation="{"horizontal" if side_by_side else "vertical"}">',
            f'{p}    <TextView',
            f'{p}        android:id="@+id/menu_widget_next{i}_day"',
            f'{p}        android:layout_width="{"52dp" if side_by_side else "match_parent"}"',
            f'{p}        android:layout_height="wrap_content"',
            f'{p}        android:maxLines="1"',
            f'{p}        android:textColor="@color/menu_widget_text"',
            f'{p}        android:textSize="13sp"',
            f'{p}        android:textStyle="bold" />',
            f'{p}    <LinearLayout',
            f'{p}        android:layout_width="{"0dp" if side_by_side else "match_parent"}"',
            f'{p}        android:layout_height="wrap_content"',
        ]
        if side_by_side:
            out.append(f'{p}        android:layout_weight="1"')
        out.append(f'{p}        android:orientation="vertical">')
        out += meal_line(p + "        ", i, "lunch", "sun")
        out += meal_line(p + "        ", i, "dinner", "moon")
        out += [f'{p}    </LinearLayout>', f'{p}</LinearLayout>']
    return out


def root(comment):
    return [
        '<?xml version="1.0" encoding="utf-8"?>',
        f'<!-- {comment} Generated by android/tools/gen_menu_widget_cards.py. -->',
        '<LinearLayout xmlns:android="http://schemas.android.com/apk/res/android"',
        '    android:id="@+id/menu_widget_root"',
        '    android:layout_width="match_parent"',
        '    android:layout_height="match_parent"',
        '    android:background="@drawable/menu_widget_background"',
    ]


wide = root("Wide and short menu widget: today on the left, the next 3 days on the right.") + [
    '    android:orientation="horizontal"',
    '    android:padding="12dp">',
]
wide += today_card(4, "0dp", "match_parent", "0.42")
wide += [
    '    <LinearLayout',
    '        android:id="@+id/menu_widget_next"',
    '        android:layout_width="0dp"',
    '        android:layout_height="match_parent"',
    '        android:layout_weight="0.58"',
    '        android:orientation="vertical"',
    '        android:paddingStart="14dp"',
    '        android:paddingTop="4dp"',
    '        android:paddingEnd="4dp">',
]
wide += next_rows(8, 3, side_by_side=True)
wide += ['    </LinearLayout>', '</LinearLayout>']

tall = root("Narrow and tall menu widget: today on top, the next 4 days below.") + [
    '    android:orientation="vertical"',
    '    android:padding="12dp">',
]
tall += today_card(4, "match_parent", "wrap_content", None)
tall += [
    '    <LinearLayout',
    '        android:id="@+id/menu_widget_next"',
    '        android:layout_width="match_parent"',
    '        android:layout_height="wrap_content"',
    '        android:orientation="vertical"',
    '        android:paddingStart="6dp"',
    '        android:paddingTop="10dp"',
    '        android:paddingEnd="6dp">',
]
tall += next_rows(8, 4, side_by_side=False)
tall += ['    </LinearLayout>', '</LinearLayout>']

out_dir = sys.argv[1]
for name, lines in (("menu_widget_wide.xml", wide), ("menu_widget_tall.xml", tall)):
    with open(os.path.join(out_dir, name), "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines) + "\n")
