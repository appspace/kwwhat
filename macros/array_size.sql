{% macro array_size(array_column) %}
    {% if target.type == 'snowflake' %}
        array_size({{ array_column }})
    {% elif target.type == 'redshift' %}
        get_array_length({{ array_column }})
    {% else %}
        cardinality({{ array_column }})
    {% endif %}
{% endmacro %}
