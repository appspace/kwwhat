{#
  Fails for every row whose id is not prefixed by its charger: port_id and connector_id must look like
  '<charger_id>-<number>' (see the network_scoped_id macro). Null ids are ignored; pair with not_null
  where the id is required.
#}
{% test scoped_by_charger(model, column_name, charger_column='charger_id') %}

select
    {{ charger_column }},
    {{ column_name }}
from {{ model }}
where {{ column_name }} is not null
    and (
        {{ charger_column }} is null
        or substr({{ column_name }}, 1, length({{ charger_column }}) + 1) != {{ dbt.concat([charger_column, "'-'"]) }}
    )

{% endtest %}
