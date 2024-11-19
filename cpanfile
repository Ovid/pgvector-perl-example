#!/usr/bin/env perl

requires 'perl', '5.040';
required 'DBI';
requires 'Data::Printer';
requires 'OpenAPI::Client::OpenAI';    # for getting embeddings
requires 'SQL::SplitStatement';
requires 'Type::Tiny';

# vim: ft=perl

=comment

Install all dependencies with:

    cpanm --installdeps . 

=cut

