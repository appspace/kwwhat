{#
  Builds a network-unique id for something numbered within a charger: '<charger_id>-<local_id>',
  e.g. charger 'CH-002' + port '1' gives 'CH-002-1'.

  OCPP numbers ports and connectors per charger (1, 2, ...), so the raw number alone is not unique
  across the network. port_id and connector_id carry this scoped form in every layer; the raw connector
  number stays available as connector_number (the OCPP connectorId). Use this macro wherever a raw OCPP number is
  turned into an id, so the formula exists in one place.

  Returns null when local_id is null (e.g. OCPP messages that carry no connectorId).
#}
{% macro network_scoped_id(charger_id, local_id) %}
    {{ dbt.concat([charger_id, "'-'", "cast(" ~ local_id ~ " as " ~ dbt.type_string() ~ ")"]) }}
{% endmacro %}
